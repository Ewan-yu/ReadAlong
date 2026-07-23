from __future__ import annotations

import json

from app.models.audio import AudioWordTiming
from app.models.errors import PipelineError
from app.models.ocr import OcrSentences
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
    implementation_version = "original-timeline-v1"
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
        recognized = self._aligner.align(vocal_path, params.language, context.cancellation)
        timeline = self._build_timeline(
            sentences,
            recognized,
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
        sentences: OcrSentences,
        recognized: tuple[AudioWordTiming, ...],
        *,
        proofread_revision: str,
        original_audio_revision: str,
        original_audio_sha256: str,
        vocal_sha256: str,
        duration_ms: int,
    ) -> OriginalTimeline:
        expected_words = tuple(word for sentence in sentences.sentences for word in normalized_words(sentence.text))
        actual_words = tuple(word for item in recognized for word in normalized_words(item.word))
        # A timeline is child-facing correctness data, not a best-effort TTS
        # convenience.  Do not synthesize estimated positions or silently drop
        # an unmatched line: leave a failed job for the parent correction gate.
        if not expected_words or actual_words != expected_words or any(len(normalized_words(item.word)) != 1 for item in recognized):
            raise PipelineError(
                "ORIGINAL_TIMELINE_WORD_MISMATCH",
                "原音识别词序与校对文本不一致，请先校正文本或重新分离后再试。",
                details={"expected_word_count": len(expected_words), "recognized_word_count": len(actual_words)},
                status_code=422,
            )
        cursor = 0
        output: list[OriginalTimelineSentence] = []
        previous_end = 0.0
        for sentence in sentences.sentences:
            count = len(normalized_words(sentence.text))
            words = tuple(
                OriginalTimelineWord(
                    seq=index + 1,
                    text=expected_words[cursor + index],
                    start_ms=round(item.t_start * 1000),
                    end_ms=round(item.t_end * 1000),
                )
                for index, item in enumerate(recognized[cursor : cursor + count])
            )
            if not words or words[0].start_ms < previous_end:
                raise PipelineError(
                    "ORIGINAL_TIMELINE_TIMING_INVALID",
                    "原音时间戳不是连续递增的，请重新生成。",
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
            cursor += count
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
