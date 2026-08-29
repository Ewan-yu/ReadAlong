from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from app.models.errors import PipelineError
from app.pipeline.definitions import CancellationToken
from app.providers.process_control import terminate_process


class FfprobeMediaProbe:
    """Read media metadata without decoding or rewriting the source asset."""

    def __init__(self, executable: Path | None = None) -> None:
        self._executable = executable

    def duration_ms(self, source: Path, cancellation: CancellationToken) -> int:
        executable = self._resolve_executable()
        cancellation.raise_if_cancelled()
        process = subprocess.Popen(
            [
                str(executable),
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "json",
                str(source),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        while process.poll() is None:
            if cancellation.requested:
                terminate_process(process)
                cancellation.raise_if_cancelled()
            time.sleep(0.05)
        stdout, stderr = process.communicate()
        if process.returncode != 0:
            raise PipelineError(
                "ORIGINAL_AUDIO_PROBE_FAILED",
                "无法读取原音音频，请确认 MP3 文件可正常播放。",
                details={"ffprobe_error": stderr[-500:]},
                status_code=422,
            )
        try:
            duration = float(json.loads(stdout)["format"]["duration"])
            duration_ms = round(duration * 1000)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise PipelineError(
                "ORIGINAL_AUDIO_PROBE_FAILED",
                "原音音频缺少有效的时长信息。",
                status_code=422,
            ) from exc
        if duration_ms <= 0:
            raise PipelineError(
                "ORIGINAL_AUDIO_PROBE_FAILED",
                "原音音频时长必须大于 0。",
                status_code=422,
            )
        return duration_ms

    def _resolve_executable(self) -> Path:
        ffmpeg_path = Path(os.environ["FFMPEG_PATH"]) if os.environ.get("FFMPEG_PATH") else None
        adjacent = None
        if ffmpeg_path is not None:
            adjacent = ffmpeg_path.with_name(
                "ffprobe.exe" if ffmpeg_path.suffix.lower() == ".exe" else "ffprobe"
            )
        candidates = (
            self._executable,
            Path(os.environ["FFPROBE_PATH"]) if os.environ.get("FFPROBE_PATH") else None,
            adjacent,
            Path(sys.prefix) / "Library" / "bin" / "ffprobe.exe",
            Path(sys.prefix) / "bin" / "ffprobe",
            Path(shutil.which("ffprobe")) if shutil.which("ffprobe") else None,
        )
        for candidate in candidates:
            if candidate is not None and candidate.is_file():
                return candidate
        raise PipelineError(
            "FFPROBE_MISSING",
            "找不到 ffprobe；请安装到 conda 环境或设置 FFPROBE_PATH。",
            status_code=422,
        )
