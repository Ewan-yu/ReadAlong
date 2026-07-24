from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from platformdirs import user_cache_path

from app.models.errors import PipelineError
from app.pipeline.definitions import CancellationToken, ProgressReporter
from app.pipeline.hashing import file_sha256


_HTDEMUCS_CHECKPOINT = "955717e8-8726e21a.th"
# Demucs filenames are `<model signature>-<checkpoint sha prefix>.th`; the
# first part identifies the model configuration, not the downloaded bytes.
_HTDEMUCS_SHA256_PREFIX = "8726e21a"


@dataclass(frozen=True)
class SeparationOutput:
    background_ogg: Path
    vocals_ogg: Path
    duration_ms: int
    report: dict[str, object]


class DemucsSeparationProvider:
    """Lazy Demucs wrapper; model packages and weights stay out of pyproject.

    Missing weights are reported instead of silently starting an unreliable
    overseas download.  The bundled PoC downloader supplies resume, retry and
    mirror support for the cache named by READALONG_DEMUCS_CACHE.
    """

    def __init__(self, model_cache: Path | None = None, ffmpeg: Path | None = None) -> None:
        self._model_cache = model_cache
        self._ffmpeg = ffmpeg

    def separate(
        self,
        source: Path,
        output: Path,
        *,
        model_name: str,
        cancellation: CancellationToken,
        progress: ProgressReporter,
    ) -> SeparationOutput:
        if model_name != "htdemucs":
            raise PipelineError("ORIGINAL_AUDIO_MODEL_INVALID", "当前仅支持 htdemucs 原音分离模型。", status_code=422)
        try:
            import torch
            from demucs.apply import apply_model
            from demucs.audio import save_audio
            from demucs.pretrained import get_model
            from demucs.separate import load_track
        except ImportError as exc:
            raise PipelineError(
                "DEMUCS_NOT_INSTALLED",
                "原音分离组件尚未安装。请按 PoC 文档在 readalong 环境安装 Demucs。",
                status_code=422,
            ) from exc

        cache = self._cache_dir()
        checkpoint = cache / "hub" / "checkpoints" / _HTDEMUCS_CHECKPOINT
        if not checkpoint.is_file() or not file_sha256(checkpoint).startswith(_HTDEMUCS_SHA256_PREFIX):
            raise PipelineError(
                "DEMUCS_MODEL_MISSING",
                "htdemucs 权重尚未准备好；请用 PoC 下载器（支持国内镜像和续传）下载后重试。",
                details={"cache": str(cache), "model": model_name},
                status_code=422,
            )
        ffmpeg = self._resolve_ffmpeg()
        cancellation.raise_if_cancelled()
        torch.hub.set_dir(str(cache / "hub"))
        device = "cuda" if torch.cuda.is_available() else "cpu"
        progress(0.05, "正在加载 htdemucs 模型。")
        started = time.perf_counter()
        model = get_model(model_name)
        model.cpu().eval()
        wav = load_track(source, model.audio_channels, model.samplerate)
        reference = wav.mean(0)
        mean, std = reference.mean(), reference.std()
        if not torch.isfinite(std) or std <= 0:
            raise PipelineError("ORIGINAL_AUDIO_INVALID", "原音缺少可用的动态范围，无法分离。", status_code=422)
        normalized = (wav - mean) / std
        if device == "cuda":
            torch.cuda.empty_cache()
            torch.cuda.reset_peak_memory_stats()
        progress(0.12, "正在分离人声与背景音。")
        inference_started = time.perf_counter()
        stems = apply_model(
            model, normalized[None], device=device, shifts=1, split=True,
            overlap=0.25, progress=False, num_workers=0,
        )[0] * std + mean
        if device == "cuda":
            torch.cuda.synchronize()
        inference_seconds = time.perf_counter() - inference_started
        vocals = stems[model.sources.index("vocals")]
        background = sum(
            (stems[index] for index, name in enumerate(model.sources) if name != "vocals"),
            start=torch.zeros_like(vocals),
        )
        raw = output / ".raw"
        raw.mkdir(parents=True, exist_ok=True)
        vocals_wav, background_wav = raw / "vocals.wav", raw / "background.wav"
        save_audio(vocals, str(vocals_wav), samplerate=model.samplerate, clip="clamp", as_float=True)
        save_audio(background, str(background_wav), samplerate=model.samplerate, clip="clamp", as_float=True)
        duration_ms = round(vocals.shape[-1] / model.samplerate * 1000)
        vocals_ogg, background_ogg = output / "preview" / "vocals.ogg", output / "background.ogg"
        progress(0.82, "正在生成试听音频。")
        self._encode(ffmpeg, vocals_wav, vocals_ogg, cancellation)
        self._encode(ffmpeg, background_wav, background_ogg, cancellation)
        self._copy_preview(background_ogg, output / "preview" / "background.ogg")
        self._write_waveform(vocals_wav, output / "waveform" / "vocals.json")
        self._write_waveform(background_wav, output / "waveform" / "background.json")
        self._write_waveform(source, output / "waveform" / "original.json")
        shutil.rmtree(raw, ignore_errors=True)
        report: dict[str, object] = {
            "schema_version": 1, "model": model_name, "device": device,
            "source_sha256": file_sha256(source), "duration_ms": duration_ms,
            "inference_seconds": inference_seconds,
            "model_load_seconds": inference_started - started,
            "peak_cuda_allocated_mb": (
                torch.cuda.max_memory_allocated() / 1024 / 1024 if device == "cuda" else None
            ),
        }
        progress(1, "原音分离候选已生成，等待试听确认。")
        return SeparationOutput(background_ogg, vocals_ogg, duration_ms, report)

    def _cache_dir(self) -> Path:
        raw = os.environ.get("READALONG_DEMUCS_CACHE")
        if raw:
            return Path(raw).expanduser().resolve()

        # Development checkouts keep the large, non-versioned weights beside
        # the repository.  A worktree is nested below that checkout, so walk
        # upwards instead of requiring every worktree to copy 400+ MB.  An
        # installed application has no such directory and continues to use
        # its normal per-user cache (or the explicit environment override).
        for root in Path(__file__).resolve().parents:
            bundled = root / "pretrained_models" / "Demucs"
            if bundled.is_dir():
                return bundled.resolve()
        return (user_cache_path("ReadAlong") / "Demucs").expanduser().resolve()

    def _resolve_ffmpeg(self) -> Path:
        candidates = (
            self._ffmpeg, Path(sys.prefix) / "Library" / "bin" / "ffmpeg.exe",
            Path(os.environ["FFMPEG_PATH"]) if os.environ.get("FFMPEG_PATH") else None,
            Path(shutil.which("ffmpeg")) if shutil.which("ffmpeg") else None,
        )
        for candidate in candidates:
            if candidate is not None and candidate.is_file():
                return candidate
        raise PipelineError("FFMPEG_MISSING", "找不到 ffmpeg，无法生成分离试听音频。", status_code=422)

    @staticmethod
    def _copy_preview(source: Path, target: Path) -> None:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)

    @staticmethod
    def _encode(ffmpeg: Path, source: Path, target: Path, cancellation: CancellationToken) -> None:
        target.parent.mkdir(parents=True, exist_ok=True)
        process = subprocess.Popen([str(ffmpeg), "-y", "-i", str(source), "-ar", "48000", "-ac", "2", "-c:a", "libopus", "-b:a", "96k", str(target)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
        while process.poll() is None:
            if cancellation.requested:
                process.terminate()
                process.wait(timeout=5)
                cancellation.raise_if_cancelled()
            time.sleep(0.05)
        _stdout, stderr = process.communicate()
        if process.returncode != 0 or not target.is_file():
            raise PipelineError("ORIGINAL_AUDIO_TRANSCODE_FAILED", "无法生成原音分离试听音频。", details={"ffmpeg_error": stderr[-500:]}, status_code=500)

    @staticmethod
    def _write_waveform(source: Path, target: Path) -> None:
        # waveform rendering is deliberately server-side; the browser never
        # receives a WAV solely to calculate peaks.
        try:
            import numpy as np
            import soundfile as sf
            data, _rate = sf.read(source, dtype="float32", always_2d=True)
        except Exception as exc:
            raise PipelineError("ORIGINAL_AUDIO_WAVEFORM_FAILED", "无法生成原音波形。", status_code=500) from exc
        bins = min(2400, max(1, len(data) // 128))
        chunks = np.array_split(data.mean(axis=1), bins)
        payload = {"schema_version": 1, "peaks": [[round(float(chunk.min()), 5), round(float(chunk.max()), 5)] for chunk in chunks if len(chunk)]}
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
