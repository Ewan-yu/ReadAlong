from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from threading import Event
import subprocess
import time

import pytest

from app.models.errors import PipelineError
from app.pipeline.definitions import CancellationToken, wait_for_future
from app.pipeline.processes import terminate_process


class _FakeProcess:
    def __init__(self, *, reap_after_kill: bool = True) -> None:
        self.terminated = False
        self.killed = False
        self.reap_after_kill = reap_after_kill
        self.communicated = False

    def terminate(self) -> None:
        self.terminated = True

    def kill(self) -> None:
        self.killed = True

    def wait(self, *, timeout: float) -> int:
        if not self.killed:
            raise subprocess.TimeoutExpired('fake', timeout)
        if not self.reap_after_kill:
            raise subprocess.TimeoutExpired('fake', timeout)
        return -9

    def communicate(self, *, timeout: float) -> tuple[str, str]:
        self.communicated = True
        return '', ''


def test_terminate_process_escalates_to_kill_and_reaps() -> None:
    process = _FakeProcess()

    terminate_process(process, terminate_timeout=0, kill_timeout=0)

    assert process.terminated is True
    assert process.killed is True
    assert process.communicated is True


def test_terminate_process_reports_unreaped_child() -> None:
    process = _FakeProcess(reap_after_kill=False)

    with pytest.raises(PipelineError) as caught:
        terminate_process(process, terminate_timeout=0, kill_timeout=0)

    assert caught.value.code == 'PROCESS_TERMINATION_FAILED'


def test_wait_for_future_returns_job_cancelled_without_waiting_for_model() -> None:
    finished = Event()
    token = CancellationToken()
    with ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(lambda: (time.sleep(0.2), finished.set()))
        token.request()

        started = time.monotonic()
        with pytest.raises(PipelineError) as caught:
            wait_for_future(future, token, poll_seconds=0.01)

        assert caught.value.code == 'JOB_CANCELLED'
        assert time.monotonic() - started < 0.1
        assert finished.wait(1)
