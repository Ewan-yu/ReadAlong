from __future__ import annotations

from pathlib import Path, PurePosixPath
from typing import Protocol

from app.models.audio import (
    AudioGenerationReport,
    AudioParams,
    AudioSentenceReport,
    AudioWordTiming,
    SynthesizedAudio,
    TtsProviderKind,
    VoiceConfig,
    VoiceMode,
    VoiceSnapshot,
)
from app.models.errors import PipelineError
from app.models.ocr import OcrSentences
from app.models.pipeline import StepId, StepResult
from app.pipeline.audio_validation import (
    estimated_word_timings,
    is_suspect_duration,
    normalized_words,
    scale_word_timings,
    validate_word_timings,
)
from app.pipeline.definitions import CancellationToken, StepRunContext
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import ensure_within
from app.providers.align import WordAligner
from app.providers.tts.ffmpeg import FfmpegOpusTranscoder
from app.providers.tts import TtsProvider


_VOICE_PROFILE_PREVIEW_WORDS = normalized_words("Hello. Let's enjoy this story together.")
_VOICE_PROFILE_ANCHOR_WORDS = normalized_words(
    "Hello. I am your reading teacher. Let's enjoy this story together."
)


class AudioTranscoder(Protocol):
    def transcode(
        self,
        wav_path: Path,
        ogg_path: Path,
        bitrate_kbps: int,
        tempo: float,
        cancellation: object,
    ) -> float: ...


class VoiceProfileResolver(Protocol):
    def snapshot_into(
        self,
        voice_id: str,
        revision: int,
        fingerprint: str,
        destination: Path,
    ) -> VoiceSnapshot: ...


class AudioStep:
    step_id = StepId.AUDIO
    implementation_version = "audio-v5"
    params_model = AudioParams

    def __init__(
        self,
        tts: TtsProvider,
        aligner: WordAligner,
        transcoder: AudioTranscoder,
        voice_profiles: VoiceProfileResolver | None = None,
    ) -> None:
        self._tts = tts
        self._aligner = aligner
        self._transcoder = transcoder
        self._voice_profiles = voice_profiles

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
        canonical_words: dict[str, AudioSentenceReport] = {}
        sentence_ids = {sentence.id for sentence in source.sentences}
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
        voice, profile_snapshot = self._resolved_voice(context, params, context.cancellation)
        voice = self._stabilize_design_voice(context, voice, params, context.cancellation)
        if voice.reference_wav_path is not None:
            outputs.append("reference/voice-reference.wav")
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
                canonical_key = self._canonical_word_key(sentence.text, params.language, params)
                canonical = canonical_words.get(canonical_key) if canonical_key else None
                if canonical is not None and canonical.audio_path:
                    source_path = ensure_within(
                        context.staging_dir,
                        context.staging_dir / Path(*PurePosixPath(canonical.audio_path).parts),
                    )
                    ogg_path.parent.mkdir(parents=True, exist_ok=True)
                    ogg_path.write_bytes(source_path.read_bytes())
                    reports.append(canonical.model_copy(update={"sentence_id": sentence.id, "audio_path": audio_path}))
                    outputs.append(audio_path)
                    context.progress(index / total, f"已复用单词音频 {index}/{total}。")
                    continue
                tts_text = self._tts_input(sentence.text)
                use_carrier = self._uses_word_carrier(sentence.text, params.language)
                carrier_text = self._word_carrier_input(sentence.text) if use_carrier else None
                synthesized, provider = self._synthesize(
                    carrier_text or tts_text,
                    voice,
                    wav_path,
                    context.cancellation,
                )
                prepared_timing: tuple[AudioWordTiming, ...] | None = None
                if carrier_text is not None:
                    try:
                        carrier_timings = self._aligner.align(
                            wav_path, params.language, context.cancellation
                        )
                        target_timing = self._carrier_target_timing(
                            sentence.text, carrier_text, carrier_timings
                        )
                        if target_timing is not None:
                            prepared_timing = self._trim_wav_to_word(
                                wav_path, target_timing
                            )
                    except PipelineError:
                        prepared_timing = None
                    if prepared_timing is None:
                        synthesized, provider = self._synthesize(
                            tts_text,
                            voice,
                            wav_path,
                            context.cancellation,
                        )
                source_timings = prepared_timing
                alignment_error: PipelineError | None = None
                if source_timings is None:
                    try:
                        source_timings = self._aligner.align(
                            wav_path, params.language, context.cancellation
                        )
                        # A rare VoxCPM bad case can return the fixed profile
                        # preview rather than the requested sentence.  It is
                        # especially confusing on the first line of a book, so
                        # retry once before allowing the audio into a revision.
                        if self._is_reference_prompt_leakage(sentence.text, source_timings):
                            synthesized, provider = self._synthesize(
                                tts_text,
                                voice,
                                wav_path,
                                context.cancellation,
                            )
                            source_timings = self._aligner.align(
                                wav_path, params.language, context.cancellation
                            )
                            if self._is_reference_prompt_leakage(sentence.text, source_timings):
                                raise PipelineError(
                                    "TTS_REFERENCE_TEXT_LEAKAGE",
                                    "语音结果混入了声音样本试听句，请重试该句。",
                                    status_code=502,
                                )
                    except PipelineError as exc:
                        if exc.code == "TTS_REFERENCE_TEXT_LEAKAGE":
                            raise
                        alignment_error = exc
                self._ensure_minimum_wav_duration(
                    Path(synthesized.wav_path), sentence.text, params.tempo
                )
                duration = self._transcoder.transcode(
                    Path(synthesized.wav_path),
                    ogg_path,
                    params.opus_bitrate_kbps,
                    params.tempo,
                    context.cancellation,
                )
                try:
                    if source_timings is None:
                        raise alignment_error or PipelineError(
                            "WORD_ALIGNMENT_EMPTY",
                            "未能从此句音频得到词级时间，将以整句字幕降级。",
                            status_code=422,
                        )
                    timing, reason = validate_word_timings(
                        sentence.text,
                        scale_word_timings(
                            source_timings,
                            1 / params.tempo,
                        ),
                        duration_seconds=duration,
                    )
                except PipelineError as exc:
                    timing, reason = None, exc.code
                if timing is None:
                    timing = estimated_word_timings(sentence.text, duration)
                    if timing:
                        reason = f"TIMING_ESTIMATED_{reason or 'UNAVAILABLE'}"
                report = AudioSentenceReport(
                    sentence_id=sentence.id,
                    audio_path=audio_path,
                    duration_seconds=duration,
                    word_timing=timing,
                    provider=provider,
                    suspect_tts=is_suspect_duration(sentence.text, duration),
                    error_code=reason,
                )
                reports.append(report)
                if canonical_key:
                    canonical_words[canonical_key] = report
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
            voice_snapshot=profile_snapshot or self._voice_snapshot(voice),
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

    def _resolved_voice(
        self,
        context: StepRunContext,
        params: AudioParams,
        cancellation: CancellationToken,
    ) -> tuple[VoiceConfig, VoiceSnapshot | None]:
        voice = params.voice
        reference = context.staging_dir / "reference" / "voice-reference.wav"
        if params.sentence_ids and params.base_audio_revision:
            previous = (
                context.workspace_dir
                / "04_audio"
                / "revisions"
                / params.base_audio_revision
                / "reference"
                / "voice-reference.wav"
            )
            legacy_anchor = previous.with_name("designed-voice-anchor.wav")
            source = previous if previous.is_file() else legacy_anchor
            if not source.is_file():
                raise PipelineError(
                    "AUDIO_VOICE_SNAPSHOT_MISSING",
                    "旧音频缺少固定声音参考，请重新生成全书以统一声线。",
                    status_code=409,
                )
            reference.parent.mkdir(parents=True, exist_ok=True)
            reference.write_bytes(source.read_bytes())
            snapshot = self._previous_voice_snapshot(context, params)
            return (
                voice.model_copy(update={"mode": VoiceMode.CLONE, "reference_wav_path": str(reference)}),
                snapshot or self._voice_snapshot_from_reference(voice, reference),
            )
        if params.voice_profile_id is not None:
            if self._voice_profiles is None:
                raise PipelineError("VOICE_PROFILE_UNAVAILABLE", "声音样本服务尚未准备完成。", status_code=409)
            snapshot = self._voice_profiles.snapshot_into(
                params.voice_profile_id,
                params.voice_profile_revision or 0,
                params.voice_fingerprint or "",
                reference,
            )
            return (
                voice.model_copy(update={"mode": VoiceMode.CLONE, "reference_wav_path": str(reference)}),
                snapshot,
            )
        if voice.reference_wav_path is None:
            return voice, None
        candidate = ensure_within(context.workspace_dir, context.workspace_dir / voice.reference_wav_path)
        if not candidate.is_file():
            raise PipelineError(
                "VOICE_REFERENCE_MISSING",
                "克隆音色所需的参考音频不存在，请重新选择或改用描述音色。",
                status_code=422,
            )
        FfmpegOpusTranscoder().normalize_reference(candidate, reference, cancellation)
        return voice.model_copy(update={"reference_wav_path": str(reference)}), None

    def _stabilize_design_voice(
        self,
        context: StepRunContext,
        voice: VoiceConfig,
        params: AudioParams,
        cancellation: CancellationToken,
    ) -> VoiceConfig:
        """Turn a designed voice into one clean, job-scoped reference voice.

        Pure text-to-voice design can vary a little between independent sentences.
        Generating a longer anchor once and then cloning it for every sentence gives
        the book a coherent speaker without inheriting music from imported audio.
        """

        if voice.mode is not VoiceMode.DESIGN:
            return voice
        reference = context.staging_dir / "reference" / "voice-reference.wav"
        previous_reference = (
            context.workspace_dir
            / "04_audio"
            / "revisions"
            / params.base_audio_revision
            / "reference"
            / "voice-reference.wav"
            if params.base_audio_revision
            else None
        )
        legacy_reference = (
            previous_reference.with_name("designed-voice-anchor.wav")
            if previous_reference is not None
            else None
        )
        if previous_reference is not None and previous_reference.is_file():
            reference.parent.mkdir(parents=True, exist_ok=True)
            reference.write_bytes(previous_reference.read_bytes())
        elif legacy_reference is not None and legacy_reference.is_file():
            reference.parent.mkdir(parents=True, exist_ok=True)
            reference.write_bytes(legacy_reference.read_bytes())
        elif params.sentence_ids:
            raise PipelineError(
                "AUDIO_VOICE_SNAPSHOT_MISSING",
                "旧音频缺少固定声音参考，请重新生成全书以统一声线。",
                status_code=409,
            )
        else:
            self._tts.synthesize(
                "Hello. I am your reading teacher. Let's enjoy this story together.",
                voice,
                reference,
                cancellation,
            )
        return voice.model_copy(
            update={"mode": VoiceMode.CLONE, "reference_wav_path": str(reference)}
        )

    @staticmethod
    def _voice_snapshot(voice: VoiceConfig) -> VoiceSnapshot | None:
        if voice.reference_wav_path is None:
            return None
        reference = Path(voice.reference_wav_path)
        if not reference.is_file():
            return None
        return VoiceSnapshot(
            name=("导入原音克隆" if voice.description == "" else voice.description),
            reference_path="reference/voice-reference.wav",
            reference_sha256=file_sha256(reference),
        )

    @staticmethod
    def _voice_snapshot_from_reference(voice: VoiceConfig, reference: Path) -> VoiceSnapshot:
        return VoiceSnapshot(
            name=("导入原音克隆" if voice.description == "" else voice.description),
            reference_path="reference/voice-reference.wav",
            reference_sha256=file_sha256(reference),
        )

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

    @staticmethod
    def _previous_voice_snapshot(
        context: StepRunContext, params: AudioParams
    ) -> VoiceSnapshot | None:
        """Carry the original profile identity forward with a partial revision.

        The copied WAV is sufficient for synthesis, but retaining this metadata is
        what lets the UI and later exports prove that a repaired sentence used the
        same immutable voice as the complete book.
        """
        if not params.base_audio_revision:
            return None
        report_path = (
            context.workspace_dir
            / "04_audio"
            / "revisions"
            / params.base_audio_revision
            / "tts_report.json"
        )
        try:
            report = AudioGenerationReport.model_validate_json(report_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return report.voice_snapshot

    def _synthesize(
        self,
        text: str,
        voice: VoiceConfig,
        output_wav: Path,
        cancellation: CancellationToken,
    ) -> tuple[SynthesizedAudio, TtsProviderKind]:
        return self._tts.synthesize(text, voice, output_wav, cancellation), TtsProviderKind.VOXCPM

    @staticmethod
    def _tts_input(text: str) -> str:
        stripped = text.strip()
        if len(normalized_words(stripped)) == 1 and stripped[-1:] not in ".?!":
            # A terminal pause encourages a complete, deliberate utterance without
            # adding another spoken word to the reader's expected transcript.
            return f"{stripped}..."
        return stripped

    @staticmethod
    def _uses_word_carrier(text: str, language: str) -> bool:
        return language.casefold().startswith("en") and len(normalized_words(text)) == 1

    @classmethod
    def _canonical_word_key(cls, text: str, language: str, params: AudioParams) -> str | None:
        """Reuse only duplicate isolated English words within one full-book run.

        This is deliberately not used for partial regeneration: pressing
        "regenerate" must still be able to make a fresh repair candidate. It also
        leaves phrases and ordinary sentences untouched, where equal text can
        legitimately need different surrounding prosody.
        """
        if params.sentence_ids or not cls._uses_word_carrier(text, language):
            return None
        return normalized_words(text)[0]

    @staticmethod
    def _is_reference_prompt_leakage(
        expected_text: str, timings: tuple[AudioWordTiming, ...]
    ) -> bool:
        """Recognize the two internal profile prompts without penalizing normal ASR drift.

        We intentionally do not reject every alignment mismatch: short names and
        isolated words are frequently transcribed imperfectly by the tiny local
        Whisper model.  These two exact transcripts, however, can only come from
        the service's own preview/reference generation and therefore justify one
        safe retry.
        """

        expected = normalized_words(expected_text)
        actual = tuple(word for item in timings for word in normalized_words(item.word))
        return actual != expected and actual in {
            _VOICE_PROFILE_PREVIEW_WORDS,
            _VOICE_PROFILE_ANCHOR_WORDS,
        }

    @staticmethod
    def _word_carrier_input(text: str) -> str:
        word = normalized_words(text)[0]
        return f"The word is {word}."

    @staticmethod
    def _carrier_target_timing(
        text: str,
        carrier_text: str,
        timings: tuple[AudioWordTiming, ...],
    ) -> AudioWordTiming | None:
        accepted, _reason = validate_word_timings(carrier_text, timings)
        if accepted is None:
            return None
        target = normalized_words(text)
        if len(target) != 1:
            return None
        for item in reversed(accepted):
            if normalized_words(item.word) == target:
                return item
        return None

    @staticmethod
    def _trim_wav_to_word(
        wav_path: Path,
        timing: AudioWordTiming,
        *,
        lead_seconds: float = 0.08,
        tail_seconds: float = 0.22,
    ) -> tuple[AudioWordTiming, ...] | None:
        """Keep only the contextualized target word and small natural margins."""

        try:
            import soundfile

            samples, sample_rate = soundfile.read(wav_path, always_2d=True)
            clip_start = max(0.0, timing.t_start - lead_seconds)
            clip_end = min(len(samples) / sample_rate, timing.t_end + tail_seconds)
            start_frame = int(clip_start * sample_rate)
            end_frame = int(clip_end * sample_rate)
            if end_frame <= start_frame:
                return None
            soundfile.write(wav_path, samples[start_frame:end_frame], sample_rate)
            return (
                AudioWordTiming(
                    word=timing.word,
                    t_start=round(timing.t_start - clip_start, 4),
                    t_end=round(timing.t_end - clip_start, 4),
                ),
            )
        except (ImportError, OSError, RuntimeError, ValueError):
            return None

    @staticmethod
    def _ensure_minimum_wav_duration(wav_path: Path, text: str, tempo: float) -> None:
        """Give short vocabulary clips enough release time before Opus encoding.

        VoxCPM can finish a one-word utterance before its final phoneme is clearly
        audible.  Padding the source WAV (rather than the encoded asset) preserves
        a stable timeline for both alignment and playback.
        """

        word_count = len(normalized_words(text))
        if not word_count:
            return
        target_output_seconds = max(0.95, 0.38 * word_count + 0.19)
        target_source_seconds = target_output_seconds * tempo
        try:
            import numpy
            import soundfile

            samples, sample_rate = soundfile.read(wav_path, always_2d=True)
            required_frames = int(target_source_seconds * sample_rate)
            if len(samples) >= required_frames:
                return
            padding = numpy.zeros((required_frames - len(samples), samples.shape[1]), dtype=samples.dtype)
            soundfile.write(wav_path, numpy.concatenate((samples, padding)), sample_rate)
        except (ImportError, OSError, RuntimeError, ValueError):
            # The production provider writes a valid WAV.  Test doubles and a later
            # transcoder still own reporting malformed source audio as an error.
            return
