from __future__ import annotations

import subprocess
from typing import Any


def terminate_process(process: Any, *, timeout: float = 5.0) -> None:
    """Best-effort bounded shutdown for an external child process.

    ffmpeg/ffprobe may have already exited, or may ignore a polite terminate
    while draining an input. A second kill prevents cancellation from leaking a
    child process and makes the caller's cancellation state deterministic.
    """

    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=timeout)
        return
    except subprocess.TimeoutExpired:
        process.kill()
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # The next communicate() still drains any captured pipes. The
            # caller will report cancellation/failure instead of hanging.
            return
