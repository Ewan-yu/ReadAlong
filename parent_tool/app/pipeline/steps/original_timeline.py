from __future__ import annotations

import json
from dataclasses import dataclass, replace
from difflib import SequenceMatcher
from pathlib import Path

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
from app.pipeline.timeline_review import union_confirmed_ids
from app.pipeline.original_timeline import (
    GENERATION_REPORT_PATH,
    MINIMUM_WORD_DURATION_MS,
    TIMELINE_PATH,
    load_and_validate_timeline,
    validate_timeline_timing_quality,
    write_timeline,
)
from app.providers.align import WordAligner


@dataclass(frozen=True)
class _VerifiedInputs:
    sentences: OcrSentences
    confirmed_root: Path
    vocal_sha256: str
    duration_ms: int


@dataclass(frozen=True)
class DiscoveryOutcome:
    """Per proofread sentence result of the discovery pass.

    Unmatched sentences are a normal part of books whose narration skips
    cover credits or word lists, but they must stay visible for human
    review instead of disappearing silently.
    """

    sentence_id: str
    narrated: bool
    reason: str | None = None
    detail: str | None = None
    previous_matched_id: str | None = None
    next_matched_id: str | None = None
    nearby_asr: tuple[str, ...] = ()


class OriginalTimelineStep:
    """Align final proofread text against the *confirmed* separated vocal stem."""

    step_id = StepId.ORIGINAL_TIMELINE
    implementation_version = "original-timeline-v8"
    params_model = OriginalTimelineParams

    def __init__(self, aligner: WordAligner, media_probe) -> None:
        self._aligner = aligner
        self._media_probe = media_probe

    def run(self, context: StepRunContext, params: OriginalTimelineParams) -> StepResult:
        inputs = self._load_verified_inputs(context)
        if params.manual_sentences:
            return self._run_manual_correction(context, params, inputs)
        vocal_path = inputs.confirmed_root / "preview" / "vocals.ogg"
        context.progress(0.05, "正在对齐已确认的人声轨与校对文本…")
        # First use local ASR only as a conservative discovery pass.  A book can
        # contain cover credits, word lists and other visual text that the
        # narrator never reads, so it is deliberately not required to cover the
        # whole OCR result.
        recognized = self._aligner.align(
            vocal_path,
            params.language,
            context.cancellation,
            model_name=params.whisper_model,
        )
        context.progress(0.45, "已识别原音朗读内容，正在校准逐句边界…")
        # Free transcription is much better at locating repeated sentence
        # boundaries in a whole-book recording.  Keep every sentence whose
        # discovery timings can be projected back to the immutable proofread
        # words.  A single ASR mismatch must not make us replace an otherwise
        # trustworthy book timeline with a whole-script forced alignment: that
        # fallback can place repeated words several seconds from their speech.
        narration, aligned, outcomes = self._project_discovery_timings(inputs.sentences.sentences, recognized)
        alignment_strategy = "discovery_projection"
        timeline = self._build_timeline(
            narration,
            aligned,
            proofread_revision=context.dependency_outputs[StepId.PROOFREAD].name,
            original_audio_revision=inputs.confirmed_root.name,
            original_audio_sha256=context.source_original_audio_sha256,
            vocal_sha256=inputs.vocal_sha256,
            duration_ms=inputs.duration_ms,
        )
        target = context.staging_dir / TIMELINE_PATH
        write_timeline(target, timeline)
        # Reparse before publish, so the written JSON itself is held to the same
        # gate as an imported/exported resource timeline.
        load_and_validate_timeline(
            target,
            sentences=inputs.sentences,
            proofread_revision=context.dependency_outputs[StepId.PROOFREAD].name,
            original_audio_revision=inputs.confirmed_root.name,
            original_audio_sha256=context.source_original_audio_sha256,
            vocal_sha256=inputs.vocal_sha256,
            duration_ms=inputs.duration_ms,
        )
        omitted = [item for item in outcomes if not item.narrated]
        report_path = context.staging_dir / GENERATION_REPORT_PATH
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(
            json.dumps(
                self._generation_report(
                    outcomes,
                    strategy=alignment_strategy,
                    whisper_model=params.whisper_model,
                    recognized_word_count=len(recognized),
                ),
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
        context.progress(1, "原音逐词时间线已生成。")
        return StepResult(
            outputs=(TIMELINE_PATH, GENERATION_REPORT_PATH),
            summary={
                "sentence_count": len(timeline.sentences),
                "omitted_sentence_count": len(omitted),
                "omitted_sentence_ids": [item.sentence_id for item in omitted],
                "whisper_model": params.whisper_model,
                "vocal_sha256": inputs.vocal_sha256,
                "alignment_strategy": alignment_strategy,
            },
        )

    def _load_verified_inputs(self, context: StepRunContext) -> _VerifiedInputs:
        """Gate both generation and correction on the same confirmed artefacts."""

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
        return _VerifiedInputs(
            sentences=sentences,
            confirmed_root=confirmed_root,
            vocal_sha256=vocal_sha256,
            duration_ms=duration_ms,
        )

    def _run_manual_correction(
        self,
        context: StepRunContext,
        params: OriginalTimelineParams,
        inputs: _VerifiedInputs,
    ) -> StepResult:
        """Republish the timeline from the parent-reviewed sentence table.

        Every submitted sentence keeps its proofread identity and text — the
        correction can only choose *which* lines are narrated and *where* they
        sit in the audio, never rewrite the reading script.  Sentences that
        keep their previous boundaries retain the ASR word timings; moved or
        newly added lines get weighted word boundaries inside the marked span.
        """
        baseline_root = context.original_timeline_output
        if baseline_root is None:
            raise PipelineError(
                "ORIGINAL_TIMELINE_MANUAL_BASE_MISSING",
                "请先自动生成逐词歌词，再进行手工修正。",
                status_code=409,
            )
        try:
            baseline = OriginalTimeline.model_validate_json(
                (baseline_root / TIMELINE_PATH).read_text(encoding="utf-8")
            )
        except (OSError, ValueError) as exc:
            raise PipelineError(
                "ORIGINAL_TIMELINE_INVALID",
                "当前歌词时间线已损坏，请重新生成后再修正。",
                status_code=409,
            ) from exc

        context.progress(0.2, "正在按手工标记重建逐词歌词…")
        proof_by_id = {item.id: item for item in inputs.sentences.sentences}
        baseline_by_id = {item.sentence_id: item for item in baseline.sentences}
        unknown = [item.sentence_id for item in params.manual_sentences if item.sentence_id not in proof_by_id]
        if unknown:
            raise PipelineError(
                "ORIGINAL_TIMELINE_MANUAL_SENTENCE_UNKNOWN",
                "手工修正包含当前校对文本中不存在的句子，请刷新校对页后重试。",
                details={"sentence_ids": unknown[:5]},
                status_code=422,
            )
        seqs = [proof_by_id[item.sentence_id].seq for item in params.manual_sentences]
        if seqs != sorted(seqs) or len(set(seqs)) != len(seqs):
            raise PipelineError(
                "ORIGINAL_TIMELINE_MANUAL_ORDER_INVALID",
                "手工修正的句子必须按绘本阅读顺序提交。",
                status_code=422,
            )

        output: list[OriginalTimelineSentence] = []
        manual_entries: list[dict] = []
        for manual in params.manual_sentences:
            proof = proof_by_id[manual.sentence_id]
            base = baseline_by_id.get(manual.sentence_id)
            if base is not None and base.start_ms == manual.start_ms and base.end_ms == manual.end_ms:
                words = base.words
                action = "kept"
            else:
                words = self._manual_words(proof.text, manual.start_ms, manual.end_ms, sentence_id=proof.id)
                action = "adjusted" if base is not None else "added"
            try:
                output.append(
                    OriginalTimelineSentence(
                        sentence_id=proof.id,
                        page_no=proof.page_no,
                        seq=proof.seq,
                        text=proof.text,
                        start_ms=manual.start_ms,
                        end_ms=manual.end_ms,
                        words=words,
                    )
                )
            except ValidationError as exc:
                raise PipelineError(
                    "ORIGINAL_TIMELINE_TIMING_UNRELIABLE",
                    "手工标记的词级时间不符合歌词契约，请调整后重试。",
                    details={"sentence_id": proof.id},
                    status_code=422,
                ) from exc
            manual_entries.append({"sentence_id": proof.id, "action": action})
        if not output:
            raise PipelineError(
                "ORIGINAL_TIMELINE_MANUAL_EMPTY",
                "手工修正至少需要保留一句歌词。",
                status_code=422,
            )
        try:
            timeline = OriginalTimeline(
                source=baseline.source,
                audio_sha256=baseline.audio_sha256,
                duration_ms=inputs.duration_ms,
                sentences=tuple(output),
            )
        except ValidationError as exc:
            raise PipelineError(
                "ORIGINAL_TIMELINE_TIMING_UNRELIABLE",
                "手工标记的句子时间重叠或超出音频范围，请调整后重试。",
                status_code=422,
            ) from exc
        validate_timeline_timing_quality(timeline)
        target = context.staging_dir / TIMELINE_PATH
        write_timeline(target, timeline)
        load_and_validate_timeline(
            target,
            sentences=inputs.sentences,
            proofread_revision=context.dependency_outputs[StepId.PROOFREAD].name,
            original_audio_revision=inputs.confirmed_root.name,
            original_audio_sha256=context.source_original_audio_sha256,
            vocal_sha256=inputs.vocal_sha256,
            duration_ms=inputs.duration_ms,
        )
        included = {item.sentence_id for item in params.manual_sentences}
        excluded = [
            item.id for item in inputs.sentences.sentences if item.id not in included
        ]
        # Excluding a line during correction is a parent decision: remember it
        # so a later ASR regeneration does not flag the same word-list line as
        # suspicious again.
        union_confirmed_ids(context.workspace_dir, excluded)
        report = {
            "schema_version": 1,
            "strategy": "manual_correction",
            "base_revision": baseline_root.name,
            "narrated_sentence_count": len(output),
            "omitted_sentence_count": len(excluded),
            "omitted": [
                {"sentence_id": identifier, "reason": "excluded_by_review"}
                for identifier in excluded
            ],
            "manual": manual_entries,
        }
        report_path = context.staging_dir / GENERATION_REPORT_PATH
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        context.progress(1, "手工修正的歌词时间线已发布。")
        return StepResult(
            outputs=(TIMELINE_PATH, GENERATION_REPORT_PATH),
            summary={
                "sentence_count": len(timeline.sentences),
                "omitted_sentence_count": len(excluded),
                "omitted_sentence_ids": excluded,
                "vocal_sha256": inputs.vocal_sha256,
                "alignment_strategy": "manual_correction",
            },
        )

    @staticmethod
    def _manual_words(
        text: str,
        start_ms: int,
        end_ms: int,
        *,
        sentence_id: str,
    ) -> tuple[OriginalTimelineWord, ...]:
        """Weighted word boundaries inside a parent-marked sentence span."""

        expected = normalized_words(text)
        if not expected:
            raise PipelineError(
                "ORIGINAL_TIMELINE_MANUAL_SENTENCE_INVALID",
                "该句子没有可用于歌词的文本。",
                details={"sentence_id": sentence_id},
                status_code=422,
            )
        total = end_ms - start_ms
        if total < len(expected) * MINIMUM_WORD_DURATION_MS:
            raise PipelineError(
                "ORIGINAL_TIMELINE_MANUAL_SPAN_TOO_SHORT",
                "标记的时间跨度不足以容纳每个词至少 30 毫秒，请扩大范围。",
                details={"sentence_id": sentence_id},
                status_code=422,
            )
        weights = [max(1, len(word.replace("'", ""))) for word in expected]
        boundaries = [start_ms]
        cumulative = 0
        for weight in weights[:-1]:
            cumulative += weight
            boundaries.append(start_ms + round(total * cumulative / sum(weights)))
        boundaries.append(end_ms)
        if any(
            boundaries[index + 1] - boundaries[index] < MINIMUM_WORD_DURATION_MS
            for index in range(len(boundaries) - 1)
        ):
            # Extreme weight ratios plus rounding can starve a word; the even
            # split is always feasible because the span was checked above.
            base, remainder = divmod(total, len(expected))
            boundaries = [start_ms]
            for index in range(len(expected)):
                boundaries.append(boundaries[index] + base + (1 if index < remainder else 0))
        return tuple(
            OriginalTimelineWord(
                seq=index,
                text=expected[index - 1],
                start_ms=boundaries[index - 1],
                end_ms=boundaries[index],
            )
            for index in range(1, len(expected) + 1)
        )

    @staticmethod
    def _generation_report(
        outcomes: tuple[DiscoveryOutcome, ...],
        *,
        strategy: str,
        whisper_model: str,
        recognized_word_count: int,
    ) -> dict:
        """Parent-tool internal diagnostics; never copied into a book package."""

        omitted = [item for item in outcomes if not item.narrated]
        return {
            "schema_version": 1,
            "strategy": strategy,
            "whisper_model": whisper_model,
            "recognized_word_count": recognized_word_count,
            "narrated_sentence_count": sum(1 for item in outcomes if item.narrated),
            "omitted_sentence_count": len(omitted),
            "omitted": [
                {
                    "sentence_id": item.sentence_id,
                    "reason": item.reason,
                    "detail": item.detail,
                    "previous_matched_id": item.previous_matched_id,
                    "next_matched_id": item.next_matched_id,
                    "nearby_asr": list(item.nearby_asr),
                }
                for item in omitted
            ],
        }

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
    ) -> tuple[tuple[OcrSentence, ...], tuple[AudioWordTiming, ...], tuple[DiscoveryOutcome, ...]]:
        """Select, project and diagnose the narrated subset in a single pass.

        The produced timeline deliberately represents the ordered subset that
        is demonstrably narrated.  This is important for books where the audio
        omits a page heading or where the recognizer misses one sentence.
        Every omission is reported with its reason so the parent tool can offer
        a playback review instead of dropping lines silently.
        """

        actual = OriginalTimelineStep._flatten_words(recognized)
        cursor = 0
        projected_sentences: list[OcrSentence] = []
        projected: list[AudioWordTiming] = []
        outcomes: list[DiscoveryOutcome] = []
        for sentence in sentences:
            expected = normalized_words(sentence.text)
            if not expected:
                continue
            found = OriginalTimelineStep._find_similar_phrase(actual, expected, cursor)
            if found is None:
                outcomes.append(
                    DiscoveryOutcome(
                        sentence_id=sentence.id,
                        narrated=False,
                        reason="no_similar_match",
                        nearby_asr=tuple(word for word, _ in actual[cursor:cursor + 8]),
                    )
                )
                continue
            index, length = found
            candidate = actual[index:index + length]
            before_end = actual[index - 1][1].t_end if index > 0 else None
            after_start = actual[index + length][1].t_start if index + length < len(actual) else None
            try:
                words = OriginalTimelineStep._project_expected_phrase(
                    expected,
                    candidate,
                    before_end=before_end,
                    after_start=after_start,
                )
            except PipelineError as exc:
                # The candidate was sufficiently similar to identify a spoken
                # line, but not sufficiently complete to safely assign every
                # proofread word a boundary.  Do not poison the remaining
                # sentences by switching the entire recording to forced mode,
                # and do not advance the cursor past a failed candidate: the
                # next sentence may still match words this window swallowed.
                outcomes.append(
                    DiscoveryOutcome(
                        sentence_id=sentence.id,
                        narrated=False,
                        reason="projection_failed",
                        detail=exc.message,
                        nearby_asr=tuple(word for word, _ in candidate),
                    )
                )
                continue
            if OriginalTimelineStep._has_excessive_internal_gap(words):
                outcomes.append(
                    DiscoveryOutcome(
                        sentence_id=sentence.id,
                        narrated=False,
                        reason="internal_gap_exceeded",
                        nearby_asr=tuple(word for word, _ in candidate),
                    )
                )
                continue
            projected_sentences.append(sentence)
            projected.extend(words)
            cursor = index + length
            outcomes.append(DiscoveryOutcome(sentence_id=sentence.id, narrated=True))
        if not projected_sentences:
            raise PipelineError(
                "ORIGINAL_TIMELINE_WORD_MISMATCH",
                "原音朗读与校对文本没有可确认的共同句子。",
                details={"recognized_word_count": len(actual)},
                status_code=422,
            )
        return (
            tuple(projected_sentences),
            tuple(projected),
            tuple(OriginalTimelineStep._with_match_neighbours(tuple(outcomes))),
        )

    @staticmethod
    def _with_match_neighbours(
        outcomes: tuple[DiscoveryOutcome, ...],
    ) -> tuple[DiscoveryOutcome, ...]:
        """Annotate each omission with the closest matched sentences around it."""

        enriched: list[DiscoveryOutcome] = []
        for index, outcome in enumerate(outcomes):
            if outcome.narrated:
                enriched.append(outcome)
                continue
            previous = next(
                (
                    outcomes[probe].sentence_id
                    for probe in range(index - 1, -1, -1)
                    if outcomes[probe].narrated
                ),
                None,
            )
            following = next(
                (
                    outcomes[probe].sentence_id
                    for probe in range(index + 1, len(outcomes))
                    if outcomes[probe].narrated
                ),
                None,
            )
            enriched.append(
                replace(outcome, previous_matched_id=previous, next_matched_id=following)
            )
        return tuple(enriched)

    @staticmethod
    def _has_excessive_internal_gap(words: tuple[AudioWordTiming, ...]) -> bool:
        """Mirror of the reader's 2.5 s in-sentence word-gap gate."""

        return any(
            words[index + 1].t_start - words[index].t_end > 2.5
            for index in range(len(words) - 1)
        )

    @staticmethod
    def _project_expected_phrase(
        expected: tuple[str, ...],
        actual: tuple[tuple[str, AudioWordTiming], ...],
        *,
        before_end: float | None = None,
        after_start: float | None = None,
    ) -> tuple[AudioWordTiming, ...]:
        """Map proofread words onto an ASR window, synthesising dropped words.

        ``before_end`` and ``after_start`` are the recognised-stream
        boundaries just outside the window.  They anchor synthesised words
        when the recognizer dropped expected words at a window edge, which
        used to discard an otherwise correctly located sentence.
        """
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
            if tag == "replace":
                interval_timings = tuple(item[1] for item in actual[actual_start:actual_end])
                interval_start = interval_timings[0].t_start
                # Use the furthest observed end when ASR word boxes overlap. The
                # old last-word boundary could be before interval_start and create
                # invalid weighted timings before the repair pass was reached.
                interval_end = max(item.t_end for item in interval_timings)
                interval_end = max(interval_end, interval_start + 0.01)
                OriginalTimelineStep._distribute_weighted(
                    output, expected, expected_start, expected_end, interval_start, interval_end
                )
                continue
            if tag == "delete":
                OriginalTimelineStep._synthesize_dropped_words(
                    output,
                    expected,
                    expected_start,
                    expected_end,
                    actual,
                    actual_start,
                    before_end=before_end,
                    after_start=after_start,
                )
                continue
            raise PipelineError(
                "ORIGINAL_TIMELINE_WORD_MISMATCH",
                "原音识别缺少校对文本中的词。",
                status_code=422,
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
    def _distribute_weighted(
        output: list[AudioWordTiming | None],
        expected: tuple[str, ...],
        expected_start: int,
        expected_end: int,
        interval_start: float,
        interval_end: float,
    ) -> None:
        """Split one spoken interval across expected words by word length."""

        words = expected[expected_start:expected_end]
        weights = [max(1, len(word.replace("'", ""))) for word in words]
        total_weight = sum(weights)
        cursor_weight = 0
        for offset, weight in enumerate(weights):
            start = interval_start + (interval_end - interval_start) * cursor_weight / total_weight
            cursor_weight += weight
            end = interval_start + (interval_end - interval_start) * cursor_weight / total_weight
            output[expected_start + offset] = AudioWordTiming(
                word=words[offset],
                t_start=start,
                t_end=end,
            )

    @staticmethod
    def _synthesize_dropped_words(
        output: list[AudioWordTiming | None],
        expected: tuple[str, ...],
        expected_start: int,
        expected_end: int,
        actual: tuple[tuple[str, AudioWordTiming], ...],
        actual_start: int,
        *,
        before_end: float | None,
        after_start: float | None,
    ) -> None:
        """Give ASR-dropped words a plausible span inside the surrounding gap.

        A leading run is anchored to the first recognised word (the dropped
        words were spoken right before it); middle and trailing runs are
        anchored to the previous recognised word.  When the gap cannot host
        the minimum word durations the sentence is left to be omitted.
        """
        count = expected_end - expected_start
        minimum_span = count * 0.04
        left = (
            actual[actual_start - 1][1].t_end
            if actual_start > 0
            else (before_end if before_end is not None else 0.0)
        )
        right = actual[actual_start][1].t_start if actual_start < len(actual) else after_start
        if right is None:
            span = minimum_span + count * 0.02
            start = left
        else:
            span = min(count * 0.5, right - left)
            start = right - span if actual_start == 0 else left
        if span < minimum_span:
            raise PipelineError(
                "ORIGINAL_TIMELINE_WORD_MISMATCH",
                "原音识别缺少校对文本中的词，且附近没有可用的朗读间隙。",
                status_code=422,
            )
        OriginalTimelineStep._distribute_weighted(
            output, expected, expected_start, expected_end, start, start + span
        )

    @staticmethod
    def _repair_short_discovery_words(
        timings: tuple[AudioWordTiming, ...],
    ) -> tuple[AudioWordTiming, ...]:
        """Repair short, overlapping or out-of-order discovery boundaries."""

        return repair_word_timings(timings, minimum_duration_seconds=0.03)

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
        # Prefer a candidate that accounts for the expected phrase's full
        # length when two windows contain the same number of recognised words.
        # Without this tie-break, a shorter prefix such as ``right into
        # Frog's`` wins over ``right into Frog's net`` for the expected
        # ``right into Frog's mitt``.  The projection then treats ``mitt`` as
        # missing and silently drops an otherwise narrated sentence.
        best: tuple[int, int, float, int, int] | None = None
        # Longer sentences widen the window: ASR can drop or hallucinate more
        # than two words once a line grows past a picture-book sentence.  Short
        # lines stay tight so a loose two-word match cannot swallow the opening
        # words of the sentence that follows.
        tolerance = 3 if len(expected) >= 4 else (2 if len(expected) == 3 else 1)
        lower = max(1, len(expected) - tolerance)
        upper = min(len(actual) - cursor, len(expected) + tolerance)
        words = [word for word, _ in actual]
        expected_set = set(expected)
        # Acceptance needs at least this many words shared with the expected
        # phrase (matching blocks are shared words), which is a cheap necessary
        # condition: SequenceMatcher is pure Python and dominated the scan cost
        # whenever unmatched word-list sentences forced repeated full passes.
        required_exact = 1 if len(expected) == 2 else max(2, round(len(expected) * .6))
        for index in range(cursor, len(actual)):
            for length in range(lower, upper + 1):
                window = words[index:index + length]
                if len(window) != length:
                    continue
                shared = 0
                for word in window:
                    if word in expected_set:
                        shared += 1
                        if shared >= required_exact:
                            break
                if shared < required_exact:
                    continue
                candidate = tuple(window)
                matcher = SequenceMatcher(a=expected, b=candidate, autojunk=False)
                ratio = matcher.ratio()
                exact = sum(block.size for block in matcher.get_matching_blocks())
                # Two-word labels (for example a publisher name) still need one
                # fully recognised word; the dropped partner can be synthesised
                # from the surrounding gap.  Longer spoken sentences tolerate
                # one ASR typo.
                accepted = (len(expected) == 2 and ratio >= .5 and exact >= 1) or (
                    len(expected) >= 3 and ratio >= .7 and exact >= max(2, round(len(expected) * .6))
                )
                rank = (exact, -abs(length - len(expected)), ratio)
                if accepted and (
                    best is None
                    or rank > (best[0], best[1], best[2])
                ):
                    best = (exact, -abs(length - len(expected)), ratio, index, length)
        # Do not return the first merely acceptable window.  A sentence can be
        # preceded by a short spoken interjection (for example ``he is me``),
        # producing an early partial match that omits the final word.  Keep the
        # highest similarity instead; ties retain the first occurrence so the
        # narration still remains chronological.
        return None if best is None else (best[3], best[4])

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
