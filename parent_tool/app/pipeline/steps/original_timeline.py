from __future__ import annotations

import json
from difflib import SequenceMatcher

from pydantic import ValidationError

from app.models.audio import AudioWordTiming
from app.models.errors import PipelineError
from app.models.ocr import OcrSentence, OcrSentences
from app.models.original_timeline import (
    OriginalTimeline,
    OriginalTimelineParams,
    OriginalTimelineSentence,
    OriginalTimelineSource,
    OriginalTimelineWord,
)
from app.models.pipeline import StepId, StepResult
from app.pipeline.audio_validation import normalized_words, repair_word_timings
from app.pipeline.definitions import StepRunContext
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import ensure_within
from app.pipeline.original_timeline import (
    MINIMUM_WORD_DURATION_MS,
    TIMELINE_PATH,
    load_and_validate_timeline,
    validate_timeline_timing_quality,
    write_timeline,
)
from app.providers.align import WordAligner


class OriginalTimelineStep:
    """Align final proofread text against the *confirmed* separated vocal stem."""

    step_id = StepId.ORIGINAL_TIMELINE
    implementation_version = "original-timeline-v6"
    params_model = OriginalTimelineParams

    def __init__(self, aligner: WordAligner, media_probe) -> None:
        self._aligner = aligner
        self._media_probe = media_probe

    def run(self, context: StepRunContext, params: OriginalTimelineParams) -> StepResult:
        confirmed_root = context.confirmed_original_audio_output
        if confirmed_root is None:
            raise PipelineError(
                "ORIGINAL_AUDIO_CONFIRMATION_REQUIRED",
                "请先试听并确认原音分离结果，再生成逐词原音字幕。",
                status_code=409,
            )
        try:
            sentences = OcrSentences.model_validate_json(
                (context.dependency_outputs[StepId.PROOFREAD] / "sentences_final.json").read_text(encoding="utf-8")
            )
            report = json.loads((confirmed_root / "separation_report.json").read_text(encoding="utf-8"))
            vocal_path = confirmed_root / "preview" / "vocals.ogg"
            vocal_sha256 = str(report["vocals_preview"]["sha256"])
            source_sha256 = str(report["source_sha256"])
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise PipelineError(
                "ORIGINAL_TIMELINE_INPUT_INVALID",
                "已确认的人声轨或校对文本已损坏，请重新分离或校对。",
                status_code=409,
            ) from exc
        if not vocal_path.is_file() or file_sha256(vocal_path) != vocal_sha256:
            raise PipelineError("ORIGINAL_TIMELINE_VOCALS_INVALID", "已确认的人声轨已损坏，请重新分离。", status_code=409)
        if not context.source_original_audio_sha256 or source_sha256 != context.source_original_audio_sha256:
            raise PipelineError("ORIGINAL_TIMELINE_SOURCE_MISMATCH", "人声轨不属于当前原音，请重新分离。", status_code=409)
        if not context.source_original_audio_path:
            raise PipelineError("ORIGINAL_TIMELINE_SOURCE_MISMATCH", "当前原音文件信息不完整，请重新导入。", status_code=409)
        original_source = ensure_within(
            context.workspace_dir, context.workspace_dir / context.source_original_audio_path
        )
        if not original_source.is_file() or file_sha256(original_source) != source_sha256:
            raise PipelineError("ORIGINAL_TIMELINE_SOURCE_MISMATCH", "当前原音文件已变化，请重新分离。", status_code=409)
        # The child player uses the raw MP3, not the separated Ogg.  Its exact
        # ffprobe duration is therefore part of the timeline contract.
        duration_ms = self._media_probe.duration_ms(original_source, context.cancellation)

        context.progress(0.05, "正在对齐已确认的人声轨与校对文本…")
        # First use local ASR only as a conservative discovery pass.  A book can
        # contain cover credits, word lists and other visual text that the
        # narrator never reads, so it is deliberately not required to cover the
        # whole OCR result.
        recognized = self._aligner.align(vocal_path, params.language, context.cancellation)
        narration = self._select_narrated_sentences(sentences, recognized)
        if not narration:
            raise PipelineError(
                "ORIGINAL_TIMELINE_WORD_MISMATCH",
                "原音朗读与校对文本没有可确认的共同句子。",
                details={"recognized_word_count": len(recognized)},
                status_code=422,
            )
        context.progress(0.45, "已识别原音朗读内容，正在校准逐句边界…")
        # Free transcription is much better at locating repeated sentence
        # boundaries in a whole-book recording.  Keep every sentence whose
        # discovery timings can be projected back to the immutable proofread
        # words.  A single ASR mismatch must not make us replace an otherwise
        # trustworthy book timeline with a whole-script forced alignment: that
        # fallback can place repeated words several seconds from their speech.
        narration, aligned = self._project_discovery_timings(narration, recognized)
        alignment_strategy = "discovery_projection"
        timeline = self._build_timeline(
            narration,
            aligned,
            proofread_revision=context.dependency_outputs[StepId.PROOFREAD].name,
            original_audio_revision=confirmed_root.name,
            original_audio_sha256=context.source_original_audio_sha256,
            vocal_sha256=vocal_sha256,
            duration_ms=duration_ms,
        )
        target = context.staging_dir / TIMELINE_PATH
        write_timeline(target, timeline)
        # Reparse before publish, so the written JSON itself is held to the same
        # gate as an imported/exported resource timeline.
        load_and_validate_timeline(
            target,
            sentences=sentences,
            proofread_revision=context.dependency_outputs[StepId.PROOFREAD].name,
            original_audio_revision=confirmed_root.name,
            original_audio_sha256=context.source_original_audio_sha256,
            vocal_sha256=vocal_sha256,
            duration_ms=duration_ms,
        )
        context.progress(1, "原音逐词时间线已生成。")
        return StepResult(
            outputs=(TIMELINE_PATH,),
            summary={
                "sentence_count": len(timeline.sentences),
                "vocal_sha256": vocal_sha256,
                "alignment_strategy": alignment_strategy,
            },
        )

    @staticmethod
    def _build_timeline(
        sentences: tuple[OcrSentence, ...],
        aligned: tuple[AudioWordTiming, ...],
        *,
        proofread_revision: str,
        original_audio_revision: str,
        original_audio_sha256: str,
        vocal_sha256: str,
        duration_ms: int,
    ) -> OriginalTimeline:
        actual_words = OriginalTimelineStep._flatten_words(aligned)
        if not actual_words:
            raise PipelineError("ORIGINAL_TIMELINE_WORD_MISMATCH", "原音中没有可识别的朗读文本。", status_code=422)
        cursor = 0
        output: list[OriginalTimelineSentence] = []
        previous_end = 0
        for sentence in sentences:
            expected_words = normalized_words(sentence.text)
            if not expected_words:
                continue
            found = OriginalTimelineStep._find_exact_phrase(actual_words, expected_words, cursor)
            if found is None:
                raise PipelineError(
                    "ORIGINAL_TIMELINE_WORD_MISMATCH",
                    "原音朗读脚本的逐词对齐结果不完整，请重新生成。",
                    details={"sentence_id": sentence.id},
                    status_code=422,
                )
            matched = actual_words[found:found + len(expected_words)]
            words = OriginalTimelineStep._timeline_words(
                expected_words, matched, previous_end, duration_ms=duration_ms
            )
            if not words:
                raise PipelineError(
                    "ORIGINAL_TIMELINE_WORD_MISMATCH",
                    "原音朗读脚本的逐词时间无效，请重新生成。",
                    details={"sentence_id": sentence.id},
                    status_code=422,
                )
            try:
                output.append(
                    OriginalTimelineSentence(
                        sentence_id=sentence.id,
                        page_no=sentence.page_no,
                        seq=sentence.seq,
                        text=sentence.text,
                        start_ms=words[0].start_ms,
                        end_ms=words[-1].end_ms,
                        words=words,
                    )
                )
            except ValidationError as exc:
                raise PipelineError(
                    "ORIGINAL_TIMELINE_TIMING_UNRELIABLE",
                    "原音逐词时间边界异常，无法可靠生成歌词，请重试。",
                    details={"sentence_id": sentence.id},
                    status_code=422,
                ) from exc
            previous_end = words[-1].end_ms
            cursor = found + len(expected_words)
        if not output:
            raise PipelineError(
                "ORIGINAL_TIMELINE_WORD_MISMATCH",
                "原音朗读与校对文本没有可确认的共同句子。",
                details={"recognized_word_count": len(actual_words)},
                status_code=422,
            )
        try:
            timeline = OriginalTimeline(
                source=OriginalTimelineSource(
                    proofread_revision=proofread_revision,
                    original_audio_revision=original_audio_revision,
                    original_audio_sha256=original_audio_sha256,
                    vocal_sha256=vocal_sha256,
                ),
                audio_sha256=original_audio_sha256,
                duration_ms=duration_ms,
                sentences=tuple(output),
            )
        except ValidationError as exc:
            raise PipelineError(
                "ORIGINAL_TIMELINE_TIMING_UNRELIABLE",
                "原音逐词时间边界异常，无法可靠生成歌词，请重试。",
                status_code=422,
            ) from exc
        validate_timeline_timing_quality(timeline)
        return timeline

    @staticmethod
    def _project_discovery_timings(
        sentences: tuple[OcrSentence, ...],
        recognized: tuple[AudioWordTiming, ...],
    ) -> tuple[tuple[OcrSentence, ...], tuple[AudioWordTiming, ...]]:
        """Project reliable discovery matches and omit isolated ASR misses.

        The produced timeline deliberately represents the ordered subset that
        is demonstrably narrated.  This is important for books where the audio
        omits a page heading or where the recognizer misses one sentence.
        """

        actual = OriginalTimelineStep._flatten_words(recognized)
        cursor = 0
        projected_sentences: list[OcrSentence] = []
        projected: list[AudioWordTiming] = []
        for sentence in sentences:
            expected = normalized_words(sentence.text)
            found = OriginalTimelineStep._find_similar_phrase(actual, expected, cursor)
            if found is None:
                continue
            index, length = found
            candidate = actual[index:index + length]
            cursor = index + length
            try:
                words = OriginalTimelineStep._project_expected_phrase(expected, candidate)
            except PipelineError:
                # The candidate was sufficiently similar to identify a spoken
                # line, but not sufficiently complete to safely assign every
                # proofread word a boundary.  Do not poison the remaining
                # sentences by switching the entire recording to forced mode.
                continue
            projected_sentences.append(sentence)
            projected.extend(words)
        if not projected_sentences:
            raise PipelineError(
                "ORIGINAL_TIMELINE_WORD_MISMATCH",
                "原音朗读内容无法可靠映射到校对文本。",
                status_code=422,
            )
        return tuple(projected_sentences), tuple(projected)

    @staticmethod
    def _project_expected_phrase(
        expected: tuple[str, ...],
        actual: tuple[tuple[str, AudioWordTiming], ...],
    ) -> tuple[AudioWordTiming, ...]:
        actual_words = tuple(word for word, _ in actual)
        matcher = SequenceMatcher(a=expected, b=actual_words, autojunk=False)
        output: list[AudioWordTiming | None] = [None] * len(expected)
        for tag, expected_start, expected_end, actual_start, actual_end in matcher.get_opcodes():
            if tag == "equal":
                for offset in range(expected_end - expected_start):
                    timing = actual[actual_start + offset][1]
                    output[expected_start + offset] = AudioWordTiming(
                        word=expected[expected_start + offset],
                        t_start=timing.t_start,
                        t_end=timing.t_end,
                    )
                continue
            if tag == "insert":
                continue
            if actual_start == actual_end or expected_start == expected_end:
                raise PipelineError(
                    "ORIGINAL_TIMELINE_WORD_MISMATCH",
                    "原音识别缺少校对文本中的词。",
                    status_code=422,
                )
            interval_timings = tuple(item[1] for item in actual[actual_start:actual_end])
            interval_start = interval_timings[0].t_start
            # Use the furthest observed end when ASR word boxes overlap. The
            # old last-word boundary could be before interval_start and create
            # invalid weighted timings before the repair pass was reached.
            interval_end = max(item.t_end for item in interval_timings)
            interval_end = max(interval_end, interval_start + 0.01)
            weights = [max(1, len(word.replace("'", ""))) for word in expected[expected_start:expected_end]]
            total_weight = sum(weights)
            cursor_weight = 0
            for offset, weight in enumerate(weights):
                start = interval_start + (interval_end - interval_start) * cursor_weight / total_weight
                cursor_weight += weight
                end = interval_start + (interval_end - interval_start) * cursor_weight / total_weight
                output[expected_start + offset] = AudioWordTiming(
                    word=expected[expected_start + offset],
                    t_start=start,
                    t_end=end,
                )
        if any(item is None for item in output):
            raise PipelineError(
                "ORIGINAL_TIMELINE_WORD_MISMATCH",
                "原音识别无法完整映射到校对文本。",
                status_code=422,
            )
        try:
            return OriginalTimelineStep._repair_short_discovery_words(
                tuple(item for item in output if item is not None)
            )
        except ValidationError as exc:
            raise PipelineError(
                "ORIGINAL_TIMELINE_TIMING_INVALID",
                "原音识别返回了无效的词级时间，已跳过该句。",
                status_code=422,
            ) from exc

    @staticmethod
    def _repair_short_discovery_words(
        timings: tuple[AudioWordTiming, ...],
    ) -> tuple[AudioWordTiming, ...]:
        """Repair short, overlapping or out-of-order discovery boundaries."""

        return repair_word_timings(timings, minimum_duration_seconds=0.03)

    @staticmethod
    def _select_narrated_sentences(
        source: OcrSentences,
        recognized: tuple[AudioWordTiming, ...],
    ) -> tuple[OcrSentence, ...]:
        """Select the ordered proofread subset that is demonstrably narrated.

        Tiny local Whisper regularly makes a small spelling error (``ruler`` /
        ``rule``), therefore discovery accepts a high word-sequence similarity.
        The following forced-alignment pass remains authoritative and only emits
        the exact proofread words.
        """
        actual = OriginalTimelineStep._flatten_words(recognized)
        selected: list[OcrSentence] = []
        cursor = 0
        for sentence in source.sentences:
            expected = normalized_words(sentence.text)
            found = OriginalTimelineStep._find_similar_phrase(actual, expected, cursor)
            if found is None:
                continue
            index, length = found
            selected.append(sentence)
            cursor = index + length
        return tuple(selected)

    @staticmethod
    def _flatten_words(timings: tuple[AudioWordTiming, ...]) -> tuple[tuple[str, AudioWordTiming], ...]:
        return tuple((word, item) for item in timings for word in normalized_words(item.word))

    @staticmethod
    def _find_exact_phrase(
        actual: tuple[tuple[str, AudioWordTiming], ...], expected: tuple[str, ...], cursor: int) -> int | None:
        for index in range(cursor, len(actual) - len(expected) + 1):
            if tuple(word for word, _ in actual[index:index + len(expected)]) == expected:
                return index
        return None

    @staticmethod
    def _find_similar_phrase(
        actual: tuple[tuple[str, AudioWordTiming], ...], expected: tuple[str, ...], cursor: int
    ) -> tuple[int, int] | None:
        if not expected:
            return None
        if len(expected) == 1:
            for index in range(cursor, len(actual)):
                if actual[index][0] == expected[0]:
                    return index, 1
            return None
        best: tuple[int, float, int, int] | None = None
        lower = max(1, len(expected) - 2)
        upper = min(len(actual) - cursor, len(expected) + 2)
        for index in range(cursor, len(actual)):
            for length in range(lower, upper + 1):
                candidate = tuple(word for word, _ in actual[index:index + length])
                if len(candidate) != length:
                    continue
                matcher = SequenceMatcher(a=expected, b=candidate, autojunk=False)
                ratio = matcher.ratio()
                exact = sum(block.size for block in matcher.get_matching_blocks())
                # Two-word labels (for example a publisher name) need an exact
                # recognition. Longer spoken sentences tolerate one ASR typo.
                accepted = (len(expected) == 2 and ratio == 1) or (
                    len(expected) >= 3 and ratio >= .7 and exact >= max(2, round(len(expected) * .6))
                )
                if accepted and (
                    best is None
                    or exact > best[0]
                    or (exact == best[0] and ratio > best[1])
                ):
                    best = (exact, ratio, index, length)
        # Do not return the first merely acceptable window.  A sentence can be
        # preceded by a short spoken interjection (for example ``he is me``),
        # producing an early partial match that omits the final word.  Keep the
        # highest similarity instead; ties retain the first occurrence so the
        # narration still remains chronological.
        return None if best is None else (best[2], best[3])

    @staticmethod
    def _timeline_words(
        expected: tuple[str, ...],
        matched: tuple[tuple[str, AudioWordTiming], ...],
        previous_end: int,
        *,
        duration_ms: int | None = None,
    ) -> tuple[OriginalTimelineWord, ...]:
        words: list[OriginalTimelineWord] = []
        last_end = previous_end
        for index, (text, (_, timing)) in enumerate(zip(expected, matched), start=1):
            start = max(round(timing.t_start * 1000), last_end)
            end = round(timing.t_end * 1000)
            if end - start < MINIMUM_WORD_DURATION_MS:
                # Forced alignment can collapse a boundary word to 10–29 ms,
                # including when the following word starts at the same instant.
                # Keep the reader's 30 ms safety contract by extending this
                # word and shifting later words forward instead of rejecting an
                # otherwise usable narration timeline.
                end = start + MINIMUM_WORD_DURATION_MS
            if duration_ms is not None and end > duration_ms:
                end = duration_ms
                start = min(start, end - MINIMUM_WORD_DURATION_MS)
                if start < last_end or end <= start:
                    raise PipelineError(
                        "ORIGINAL_TIMELINE_TIMING_UNRELIABLE",
                        "原音逐词时间超出音频范围，无法可靠生成歌词，请重试。",
                        details={"word": text},
                        status_code=422,
                    )
            words.append(OriginalTimelineWord(seq=index, text=text, start_ms=start, end_ms=end))
            last_end = end
        return tuple(words)
