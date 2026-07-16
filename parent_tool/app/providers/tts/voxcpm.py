from __future__ import annotations

import os
from pathlib import Path
from threading import Lock
from typing import Protocol

from app.models.audio import SynthesizedAudio, VoiceConfig, VoiceMode
from app.models.errors import PipelineError
from app.pipeline.definitions import CancellationToken


class TtsProvider(Protocol):
    def synthesize(
        self,
        text: str,
        voice: VoiceConfig,
        output_wav: Path,
        cancellation: CancellationToken,
    ) -> SynthesizedAudio: ...


class VoxCpmTtsProvider:
    """Lazy in-process VoxCPM adapter; model loading never happens at service startup."""

    def __init__(self, model_path: Path | None = None) -> None:
        configured = os.environ.get("VOXCPM_MODEL_PATH")
        self._model_path = model_path or (Path(configured) if configured else None)
        self._model: object | None = None
        self._lock = Lock()

    def synthesize(
        self,
        text: str,
        voice: VoiceConfig,
        output_wav: Path,
        cancellation: CancellationToken,
    ) -> SynthesizedAudio:
        cancellation.raise_if_cancelled()
        model = self._load_model()
        prompt = f"({voice.description}){text}" if voice.mode is VoiceMode.DESIGN else text
        try:
            if voice.mode is VoiceMode.CLONE:
                waveform = model.generate(text=prompt, reference_wav_path=voice.reference_wav_path)
            else:
                waveform = model.generate(text=prompt, cfg_value=2.0, inference_timesteps=10)
            sample_rate = int(model.tts_model.sample_rate)
            import soundfile as sound_file

            cancellation.raise_if_cancelled()
            output_wav.parent.mkdir(parents=True, exist_ok=True)
            sound_file.write(output_wav, waveform, sample_rate)
            cancellation.raise_if_cancelled()
            return SynthesizedAudio(wav_path=str(output_wav), sample_rate=sample_rate)
        except PipelineError:
            raise
        except Exception as exc:
            raise PipelineError(
                "TTS_SYNTHESIS_FAILED",
                "VoxCPM 未能生成此句音频，请重试该句。",
                status_code=502,
            ) from exc

    def _load_model(self):
        with self._lock:
            if self._model is not None:
                return self._model
            if self._model_path is None or not self._model_path.is_dir():
                raise PipelineError(
                    "TTS_MODEL_MISSING",
                    "找不到 VoxCPM 模型；请设置 VOXCPM_MODEL_PATH。",
                    status_code=422,
                )
            try:
                from voxcpm import VoxCPM

                self._model = VoxCPM.from_pretrained(str(self._model_path), load_denoiser=False)
            except Exception as exc:
                raise PipelineError(
                    "TTS_MODEL_LOAD_FAILED",
                    "VoxCPM 模型无法加载，请检查 GPU、模型文件和依赖。",
                    status_code=500,
                ) from exc
            return self._model
