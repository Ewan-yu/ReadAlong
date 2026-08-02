from __future__ import annotations

import subprocess
from typing import Any

from app.models.errors import PipelineError


def terminate_process(
    process: subprocess.Popen[Any],
    *,
    terminate_timeout: float = 5,
    kill_timeout: float = 2,
) -> None:
    """Stop an external media process and guarantee it is reaped.

    ffmpeg/ffprobe normally honor SIGTERM, but a stuck child must not turn a
    user cancellation into ``TimeoutExpired`` or leak a process.  We escalate
    to kill, drain the pipes, and report a distinct internal error only if the
    operating system still refuses to reap the child.
    """
    process.terminate()
    try:
        process.wait(timeout=terminate_timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        try:
            process.wait(timeout=kill_timeout)
        except subprocess.TimeoutExpired as exc:
            raise PipelineError(
                "PROCESS_TERMINATION_FAILED",
                "无法停止后台媒体进程，请重启家长端后重试。",
                status_code=500,
            ) from exc
    finally:
        try:
            process.communicate(timeout=0.5)
        except (subprocess.TimeoutExpired, OSError):
            # The wait/kill path above is authoritative.  There is no useful
            # user action if a pipe itself cannot be drained during teardown.
            pass
