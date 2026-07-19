from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from app.models.errors import PipelineError
from app.pipeline.definitions import CancellationToken


class FfmpegOpusTranscoder:
    def __init__(self, executable: Path | None = None) -> None:
        self._executable = executable

    def transcode(
        self,
        wav_path: Path,
        ogg_path: Path,
        bitrate_kbps: int,
        tempo: float,
        cancellation: CancellationToken,
    ) -> float:
        ffmpeg = self._resolve_executable()
        cancellation.raise_if_cancelled()
        ogg_path.parent.mkdir(parents=True, exist_ok=True)
        process = subprocess.Popen(
            [
                str(ffmpeg),
                "-y",
                "-i",
                str(wav_path),
                "-ar",
                "48000",
                "-ac",
                "1",
                "-af",
                f"atempo={tempo},alimiter=limit=0.891:level=disabled",
                "-c:a",
                "libopus",
                "-b:a",
                f"{bitrate_kbps}k",
                str(ogg_path),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        while process.poll() is None:
            if cancellation.requested:
                process.terminate()
                process.wait(timeout=5)
                cancellation.raise_if_cancelled()
            time.sleep(0.1)
        _stdout, stderr = process.communicate()
        if process.returncode != 0 or not ogg_path.is_file():
            raise PipelineError(
                "AUDIO_TRANSCODE_FAILED",
                "音频转为 Opus 失败，请检查 ffmpeg。",
                details={"ffmpeg_error": stderr[-500:]},
                status_code=500,
            )
        try:
            import soundfile

            duration = len(soundfile.SoundFile(ogg_path)) / soundfile.info(ogg_path).samplerate
        except Exception as exc:
            raise PipelineError(
                "AUDIO_DURATION_READ_FAILED",
                "无法读取转码后音频时长。",
                status_code=500,
            ) from exc
        return float(duration)

    def normalize_reference(
        self,
        source_path: Path,
        target_path: Path,
        cancellation: CancellationToken,
        *,
        start_seconds: float = 0,
        max_seconds: int = 15,
    ) -> None:
        """Create a small, model-ready voice reference from an imported audio file."""
        ffmpeg = self._resolve_executable()
        cancellation.raise_if_cancelled()
        target_path.parent.mkdir(parents=True, exist_ok=True)
        process = subprocess.Popen(
            [
                str(ffmpeg),
                "-y",
                "-ss",
                str(start_seconds),
                "-i",
                str(source_path),
                "-t",
                str(max_seconds),
                "-ar",
                "16000",
                "-ac",
                "1",
                "-c:a",
                "pcm_s16le",
                str(target_path),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        while process.poll() is None:
            if cancellation.requested:
                process.terminate()
                process.wait(timeout=5)
                cancellation.raise_if_cancelled()
            time.sleep(0.1)
        _stdout, stderr = process.communicate()
        if process.returncode != 0 or not target_path.is_file() or target_path.stat().st_size == 0:
            raise PipelineError(
                "VOICE_REFERENCE_INVALID",
                "导入原音无法转换为可用的克隆参考片段。",
                details={"ffmpeg_error": stderr[-500:]},
                status_code=422,
            )

    def _resolve_executable(self) -> Path:
        candidates = (
            self._executable,
            Path(sys.prefix) / "Library" / "bin" / "ffmpeg.exe",
            Path(os.environ["FFMPEG_PATH"]) if os.environ.get("FFMPEG_PATH") else None,
            Path(shutil.which("ffmpeg")) if shutil.which("ffmpeg") else None,
        )
        for candidate in candidates:
            if candidate is not None and candidate.is_file():
                return candidate
        raise PipelineError(
            "FFMPEG_MISSING",
            "找不到 ffmpeg；请安装到 conda 环境或设置 FFMPEG_PATH。",
            status_code=422,
        )
