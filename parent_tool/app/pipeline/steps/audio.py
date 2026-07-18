from __future__ import annotations

from pathlib import Path, PurePosixPath
from typing import Protocol

from app.models.audio import (
    AudioGenerationReport,
    AudioParams,
    AudioSentenceReport,
    SynthesizedAudio,
    TtsProviderKind,
    VoiceConfig,
)
from app.models.errors import PipelineError
from app.models.ocr import OcrSentences
from app.models.pipeline import StepId, StepResult
from app.pipeline.audio_validation import is_suspect_duration, validate_word_timings
from app.pipeline.audio_validation import normalized_words
from app.pipeline.definitions import CancellationToken, StepRunContext
from app.pipeline.paths import ensure_within
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
    implementation_version = "audio-v2"
    params_model = AudioParams

    def __init__(
        self,
        tts: TtsProvider,
        aligner: WordAligner,
        transcoder: AudioTranscoder,
        *,
        azure_tts: TtsProvider | None = None,
    ) -> None:
        self._tts = tts
        self._azure_tts = azure_tts
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
        sentence_ids = {sentence.id for sentence in source.sentences}
        unknown_azure_ids = set(params.azure_sentence_ids) - sentence_ids
        if unknown_azure_ids:
            raise PipelineError(
                "AUDIO_PROVIDER_SENTENCE_UNKNOWN",
                "指定 Azure 语音的句子不在当前校对版本中。",
                details={"sentence_ids": sorted(unknown_azure_ids)},
                status_code=422,
            )
        targets = set(params.sentence_ids) if params.sentence_ids else sentence_ids
        unknown_targets = targets - sentence_ids
        if unknown_targets:
            raise PipelineError(
                "AUDIO_SENTENCE_UNKNOWN",
                "要重新生成的句子不在当前校对版本中。",
                details={"sentence_ids": sorted(unknown_targets)},
                status_code=422,
            )
        previous = self._previous_reports(context, params, source_root)
        voice = self._resolved_voice(context, params.voice)
        total = max(len(source.sentences), 1)
        for index, sentence in enumerate(source.sentences, start=1):
            context.cancellation.raise_if_cancelled()
            if sentence.id not in targets:
                prior = previous.get(sentence.id)
                if prior is None:
                    raise PipelineError(
                        "AUDIO_REUSE_MISSING",
                        "旧音频报告缺少未重生成的句子，请改为重新生成全书。",
                        details={"sentence_id": sentence.id},
                        status_code=409,
                    )
                reports.append(prior)
                if prior.audio_path:
                    source_path = ensure_within(
                        context.workspace_dir / "04_audio" / "revisions" / params.base_audio_revision,
                        context.workspace_dir / "04_audio" / "revisions" / params.base_audio_revision / Path(*PurePosixPath(prior.audio_path).parts),
                    )
                    target_path = ensure_within(
                        context.staging_dir, context.staging_dir / Path(*PurePosixPath(prior.audio_path).parts)
                    )
                    target_path.parent.mkdir(parents=True, exist_ok=True)
                    target_path.write_bytes(source_path.read_bytes())
                    outputs.append(prior.audio_path)
                continue
            wav_path = context.staging_dir / "wav" / f"{sentence.id}.wav"
            audio_path = f"ogg/{sentence.id}.ogg"
            ogg_path = context.staging_dir / audio_path
            try:
                synthesized, provider = self._synthesize(
                    self._tts_input(sentence.text),
                    voice,
                    wav_path,
                    context.cancellation,
                    primary_provider=(
                        TtsProviderKind.AZURE
                        if sentence.id in params.azure_sentence_ids
                        else params.primary_provider
                    ),
                    fallback_provider=params.fallback_provider,
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
                        provider=provider,
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
    def _resolved_voice(context: StepRunContext, voice: VoiceConfig) -> VoiceConfig:
        if voice.reference_wav_path is None:
            return voice
        candidate = ensure_within(context.workspace_dir, context.workspace_dir / voice.reference_wav_path)
        if not candidate.is_file():
            raise PipelineError(
                "VOICE_REFERENCE_MISSING",
                "克隆音色所需的参考音频不存在，请重新选择或改用描述音色。",
                status_code=422,
            )
        return voice.model_copy(update={"reference_wav_path": str(candidate)})

    @staticmethod
    def _previous_reports(
        context: StepRunContext, params: AudioParams, source_root: Path,
    ) -> dict[str, AudioSentenceReport]:
        if not params.sentence_ids or not params.base_audio_revision:
            return {}
        root = context.workspace_dir / "04_audio" / "revisions" / params.base_audio_revision
        try:
            report = AudioGenerationReport.model_validate_json(
                (root / "tts_report.json").read_text(encoding="utf-8")
            )
        except (OSError, ValueError) as exc:
            raise PipelineError(
                "AUDIO_REUSE_INVALID",
                "要复用的音频修订不存在或已损坏，请重新生成全书。",
                status_code=409,
            ) from exc
        if report.source_proofread_revision != source_root.name:
            raise PipelineError(
                "AUDIO_REUSE_STALE",
                "校对结果已更新，不能复用旧音频，请重新生成全书。",
                status_code=409,
            )
        for item in report.sentences:
            if item.sentence_id in params.sentence_ids:
                continue
            if item.audio_path and not (root / item.audio_path).is_file():
                raise PipelineError(
                    "AUDIO_REUSE_INVALID",
                    "要复用的音频文件缺失，请重新生成全书。",
                    details={"sentence_id": item.sentence_id},
                    status_code=409,
                )
        return {item.sentence_id: item for item in report.sentences}

    def _synthesize(
        self,
        text: str,
        voice: VoiceConfig,
        output_wav: Path,
        cancellation: CancellationToken,
        *,
        primary_provider: TtsProviderKind,
        fallback_provider: TtsProviderKind | None,
    ) -> tuple[SynthesizedAudio, TtsProviderKind]:
        try:
            provider = self._provider(primary_provider)
            return provider.synthesize(text, voice, output_wav, cancellation), primary_provider
        except PipelineError as primary_error:
            if primary_error.code == "JOB_CANCELLED" or fallback_provider in (None, primary_provider):
                raise
            try:
                fallback = self._provider(fallback_provider)
                return fallback.synthesize(text, voice, output_wav, cancellation), fallback_provider
            except PipelineError as fallback_error:
                if fallback_error.code == "JOB_CANCELLED":
                    raise
                raise PipelineError(
                    "TTS_FALLBACK_FAILED",
                    "首选和备用语音服务均未能生成此句音频。",
                    details={
                        "primary_provider": primary_provider.value,
                        "primary_error": primary_error.code,
                        "fallback_provider": fallback_provider.value,
                        "fallback_error": fallback_error.code,
                    },
                    status_code=502,
                ) from fallback_error

    def _provider(self, provider: TtsProviderKind) -> TtsProvider:
        if provider is TtsProviderKind.VOXCPM:
            return self._tts
        if provider is TtsProviderKind.AZURE and self._azure_tts is not None:
            return self._azure_tts
        raise PipelineError(
            "AZURE_TTS_UNAVAILABLE",
            "当前服务未安装 Azure Speech Provider。",
            status_code=422,
        )

    @staticmethod
    def _tts_input(text: str) -> str:
        stripped = text.strip()
        if len(normalized_words(stripped)) == 1 and stripped[-1:] not in ".?!":
            return f"{stripped}."
        return stripped
