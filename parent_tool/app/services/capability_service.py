from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from app.models.capabilities import CapabilityGroup, CapabilityStatus


class CapabilityService:
    def inspect(self) -> tuple[CapabilityStatus, ...]:
        return (
            self._voxcpm(),
            self._ffmpeg(),
            self._paddle(),
        )

    @staticmethod
    def _voxcpm() -> CapabilityStatus:
        configured = os.environ.get("VOXCPM_MODEL_PATH")
        model_exists = bool(configured and Path(configured).expanduser().is_dir())
        gpu_available = CapabilityService._has_nvidia_gpu()
        available = model_exists and gpu_available
        if not model_exists:
            detail = "未找到模型，请设置 VOXCPM_MODEL_PATH"
        elif not gpu_available:
            detail = "模型已找到，但未检测到可用 NVIDIA GPU"
        else:
            detail = "本地 GPU 与模型已就绪"
        return CapabilityStatus(
            id="voxcpm",
            name="VoxCPM 语音合成",
            group=CapabilityGroup.LOCAL,
            available=available,
            detail=detail,
        )

    @staticmethod
    def _has_nvidia_gpu() -> bool:
        executable = shutil.which("nvidia-smi")
        if executable is None:
            return False
        try:
            result = subprocess.run(
                [executable, "-L"],
                capture_output=True,
                check=False,
                timeout=2,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        return result.returncode == 0 and bool(result.stdout.strip())

    @staticmethod
    def _ffmpeg() -> CapabilityStatus:
        configured = os.environ.get("FFMPEG_PATH")
        candidates = (
            Path(configured).expanduser() if configured else None,
            Path(sys.prefix) / "Library" / "bin" / "ffmpeg.exe",
            Path(shutil.which("ffmpeg")) if shutil.which("ffmpeg") else None,
        )
        available = any(candidate is not None and candidate.is_file() for candidate in candidates)
        return CapabilityStatus(
            id="ffmpeg",
            name="ffmpeg 音频转码",
            group=CapabilityGroup.LOCAL,
            available=available,
            detail="已就绪" if available else "未找到，请安装到当前环境或设置 FFMPEG_PATH",
        )

    @staticmethod
    def _paddle() -> CapabilityStatus:
        configured = bool(os.environ.get("PADDLE_TOKEN"))
        return CapabilityStatus(
            id="paddle-ocr",
            name="PaddleOCR 文字识别",
            group=CapabilityGroup.CLOUD,
            available=configured,
            detail="Token 已配置" if configured else "未配置，请设置 PADDLE_TOKEN",
        )
