from __future__ import annotations

from pathlib import Path
from typing import Protocol

from app.models.audio import AudioGenerationReport, AudioParams, AudioSentenceReport
from app.models.errors import PipelineError
from app.models.ocr import OcrSentences
from app.models.pipeline import StepId, StepResult
from app.pipeline.audio_validation import is_suspect_duration, validate_word_timings
from app.pipeline.audio_validation import normalized_words
from app.pipeline.definitions import StepRunContext
from app.providers.align import WordAligner
from app.providers.tts import TtsProvider


class AudioTranscoder(Protocol):
    def transcode(
        self,
        wav_path: Path,
        ogg_path: Path,
        bitrate_kbps: int,
        tempo: float,
        cancellation: object,
    ) -> float: ...


class AudioStep:
    step_id = StepId.AUDIO
    implementation_version = "audio-v1"
    params_model = AudioParams

    def __init__(self, tts: TtsProvider, aligner: WordAligner, transcoder: AudioTranscoder) -> None:
        self._tts = tts
        self._aligner = aligner
        self._transcoder = transcoder

    def run(self, context: StepRunContext, params: AudioParams) -> StepResult:
        source_root = context.dependency_outputs[StepId.PROOFREAD]
        try:
            source = OcrSentences.model_validate_json(
                (source_root / "sentences_final.json").read_text(encoding="utf-8")
            )
        except (OSError, ValueError) as exc:
            raise PipelineError(
                "AUDIO_INPUT_INVALID",
                "校对后的句子表不存在或已损坏。",
                status_code=409,
            ) from exc
        reports: list[AudioSentenceReport] = []
        outputs: list[str] = []
        total = max(len(source.sentences), 1)
        for index, sentence in enumerate(source.sentences, start=1):
            context.cancellation.raise_if_cancelled()
            wav_path = context.staging_dir / "wav" / f"{sentence.id}.wav"
            audio_path = f"ogg/{sentence.id}.ogg"
            ogg_path = context.staging_dir / audio_path
            try:
                synthesized = self._tts.synthesize(
                    self._tts_input(sentence.text),
                    params.voice,
                    wav_path,
                    context.cancellation,
                )
                duration = self._transcoder.transcode(
                    Path(synthesized.wav_path),
                    ogg_path,
                    params.opus_bitrate_kbps,
                    params.tempo,
                    context.cancellation,
                )
                try:
                    timing, reason = validate_word_timings(
                        sentence.text,
                        self._aligner.align(wav_path, params.language, context.cancellation),
                    )
                except PipelineError as exc:
                    timing, reason = None, exc.code
                reports.append(
                    AudioSentenceReport(
                        sentence_id=sentence.id,
                        audio_path=audio_path,
                        duration_seconds=duration,
                        word_timing=timing,
                        suspect_tts=is_suspect_duration(sentence.text, duration),
                        error_code=reason,
                    )
                )
                outputs.append(audio_path)
            except PipelineError as exc:
                reports.append(AudioSentenceReport(sentence_id=sentence.id, error_code=exc.code))
            finally:
                wav_path.unlink(missing_ok=True)
            context.progress(index / total, f"已生成句子 {index}/{total} 的音频。")
        report = AudioGenerationReport(
            source_proofread_revision=source_root.name,
            params=params,
            sentences=tuple(reports),
        )
        for name in ("word_timings.json", "tts_report.json"):
            (context.staging_dir / name).write_text(report.model_dump_json(indent=2), encoding="utf-8")
        outputs.extend(("word_timings.json", "tts_report.json"))
        context.progress(1, "语音生成完成。")
        return StepResult(
            outputs=tuple(outputs),
            summary={
                "sentence_count": len(reports),
                "audio_count": sum(item.audio_path is not None for item in reports),
                "failed_count": sum(item.audio_path is None for item in reports),
            },
        )

    @staticmethod
    def _tts_input(text: str) -> str:
        stripped = text.strip()
        if len(normalized_words(stripped)) == 1 and stripped[-1:] not in ".?!":
            return f"{stripped}."
        return stripped
