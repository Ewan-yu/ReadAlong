from __future__ import annotations

import json
from difflib import SequenceMatcher

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
from app.pipeline.audio_validation import normalized_words
from app.pipeline.definitions import StepRunContext
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import ensure_within
from app.pipeline.original_timeline import TIMELINE_PATH, load_and_validate_timeline, write_timeline
from app.providers.align import WordAligner


class OriginalTimelineStep:
    """Align final proofread text against the *confirmed* separated vocal stem."""

    step_id = StepId.ORIGINAL_TIMELINE
    implementation_version = "original-timeline-v2"
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
        context.progress(0.45, "已识别原音朗读内容，正在进行逐词强制对齐…")
        aligned = self._aligner.align_script(
            vocal_path,
            "\n".join(sentence.text for sentence in narration),
            params.language,
            context.cancellation,
        )
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
            summary={"sentence_count": len(timeline.sentences), "vocal_sha256": vocal_sha256},
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
            words = OriginalTimelineStep._timeline_words(expected_words, matched, previous_end)
            if not words:
                raise PipelineError(
                    "ORIGINAL_TIMELINE_WORD_MISMATCH",
                    "原音朗读脚本的逐词时间无效，请重新生成。",
                    details={"sentence_id": sentence.id},
                    status_code=422,
                )
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
            previous_end = words[-1].end_ms
            cursor = found + len(expected_words)
        if not output:
            raise PipelineError(
                "ORIGINAL_TIMELINE_WORD_MISMATCH",
                "原音朗读与校对文本没有可确认的共同句子。",
                details={"recognized_word_count": len(actual_words)},
                status_code=422,
            )
        return OriginalTimeline(
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
        best: tuple[float, int, int] | None = None
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
                if accepted and (best is None or ratio > best[0]):
                    best = (ratio, index, length)
            # Prefer the first qualified occurrence when scores are equal: it
            # preserves chronological narration and avoids jumping to a repeat.
            if best is not None and best[1] == index:
                return best[1], best[2]
        return None

    @staticmethod
    def _timeline_words(
        expected: tuple[str, ...],
        matched: tuple[tuple[str, AudioWordTiming], ...],
        previous_end: int,
    ) -> tuple[OriginalTimelineWord, ...]:
        words: list[OriginalTimelineWord] = []
        last_end = previous_end
        for index, (text, (_, timing)) in enumerate(zip(expected, matched), start=1):
            start = max(round(timing.t_start * 1000), last_end)
            end = round(timing.t_end * 1000)
            if end <= start:
                # Stable-ts can expose two boundaries in the same millisecond.
                # Give the displayed word a minimal positive span; later words
                # are shifted forward too, keeping the timeline monotonic.
                end = start + 10
            words.append(OriginalTimelineWord(seq=index, text=text, start_ms=start, end_ms=end))
            last_end = end
        return tuple(words)
