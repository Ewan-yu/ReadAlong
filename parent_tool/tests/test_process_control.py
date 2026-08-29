from __future__ import annotations

import subprocess

from app.providers.process_control import terminate_process


class _StubbornProcess:
    def __init__(self) -> None:
        self.terminated = False
        self.killed = False
        self.wait_calls = 0

    def poll(self) -> int | None:
        return None if not self.killed else -9

    def terminate(self) -> None:
        self.terminated = True

    def kill(self) -> None:
        self.killed = True

    def wait(self, *, timeout: float) -> None:
        self.wait_calls += 1
        if self.wait_calls == 1:
            raise subprocess.TimeoutExpired("fake-child", timeout)


def test_terminate_process_escalates_when_child_ignores_terminate() -> None:
    process = _StubbornProcess()

    terminate_process(process, timeout=0.01)

    assert process.terminated
    assert process.killed
    assert process.wait_calls == 2
