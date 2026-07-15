import asyncio
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event

import pytest
from pydantic import BaseModel, ConfigDict

from app.jobs.events import EventBus, JobEvent
from app.jobs.manager import JobManager
from app.jobs.repository import JobRepository
from app.models.errors import PipelineError
from app.models.jobs import JobSnapshot, JobStatus
from app.models.pipeline import PipelineState, StepId, StepResult, utc_now
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import StepRegistry
from app.pipeline.engine import PipelineEngine, SkippedRun
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository


class JobParams(BaseModel):
    model_config = ConfigDict(extra="forbid")

    value: str


class BlockingStep:
    step_id = StepId.PAGES
    implementation_version = "job-test-v1"
    params_model = JobParams

    def __init__(self, *, blocking: bool) -> None:
        self.blocking = blocking
        self.started = Event()
        self.release = Event()

    def run(self, context, params):
        self.started.set()
        context.progress(0.25, "started")
        while self.blocking and not self.release.wait(0.01):
            context.cancellation.raise_if_cancelled()
        context.cancellation.raise_if_cancelled()
        (context.staging_dir / "result.txt").write_text(params.value, encoding="utf-8")
        context.progress(1.0, "done")
        return StepResult(outputs=("result.txt",))


def _manager(tmp_path: Path, step: BlockingStep) -> tuple[JobManager, JobRepository]:
    paths = WorkspacePaths(tmp_path)
    states = StateRepository(paths)
    states.create(PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64))
    engine = PipelineEngine(states, ArtifactStore(paths), StepRegistry((step,)))
    jobs = JobRepository(paths)
    manager = JobManager(
        engine,
        jobs,
        EventBus(queue_size=2),
        executor=ThreadPoolExecutor(max_workers=1, thread_name_prefix="test-pipeline"),
    )
    return manager, jobs


def test_job_runs_to_persisted_success(tmp_path: Path) -> None:
    manager, jobs = _manager(tmp_path, BlockingStep(blocking=False))
    try:
        started = manager.start("book-1", StepId.PAGES, {"value": "ok"})
        assert not isinstance(started, SkippedRun)

        completed = manager.wait(started.job_id, timeout=2)

        assert completed.status is JobStatus.SUCCEEDED
        assert completed.progress == 1
        assert completed.finished_at is not None
        assert jobs.load(started.job_id) == completed
    finally:
        manager.shutdown()


def test_global_active_slot_rejects_second_job(tmp_path: Path) -> None:
    step = BlockingStep(blocking=True)
    manager, _ = _manager(tmp_path, step)
    try:
        first = manager.start("book-1", StepId.PAGES, {"value": "first"})
        assert not isinstance(first, SkippedRun)
        assert step.started.wait(1)

        with pytest.raises(PipelineError) as caught:
            manager.start("book-1", StepId.PAGES, {"value": "second"})

        assert caught.value.code == "JOB_ALREADY_RUNNING"
        assert caught.value.details["job_id"] == first.job_id
        step.release.set()
        assert manager.wait(first.job_id, timeout=2).status is JobStatus.SUCCEEDED
    finally:
        step.release.set()
        manager.shutdown()


def test_cancelled_job_releases_slot(tmp_path: Path) -> None:
    step = BlockingStep(blocking=True)
    manager, _ = _manager(tmp_path, step)
    try:
        started = manager.start("book-1", StepId.PAGES, {"value": "first"})
        assert not isinstance(started, SkippedRun)
        assert step.started.wait(1)

        cancelling = manager.cancel(started.job_id)
        completed = manager.wait(started.job_id, timeout=2)

        assert cancelling.cancel_requested is True
        assert completed.status is JobStatus.CANCELLED
        assert manager.active_job_id is None
    finally:
        step.release.set()
        manager.shutdown()


def test_job_repository_recovers_nonterminal_snapshots(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path)
    jobs = JobRepository(paths)
    now = utc_now()
    snapshot = JobSnapshot(
        job_id="12345678-1234-4234-8234-123456789abc",
        book_id="book-1",
        step_id=StepId.PAGES,
        status=JobStatus.RUNNING,
        progress=0.5,
        message="running",
        created_at=now,
        updated_at=now,
        started_at=now,
    )
    jobs.create(snapshot)

    recovered = jobs.recover_nonterminal()

    assert len(recovered) == 1
    assert recovered[0].status is JobStatus.INTERRUPTED
    assert recovered[0].error is not None
    assert recovered[0].error.code == "PROCESS_INTERRUPTED"
    assert jobs.recover_nonterminal() == ()


def test_event_bus_drops_intermediate_events_without_blocking() -> None:
    async def scenario() -> list[str]:
        bus = EventBus(queue_size=2)
        async with bus.subscribe("job-1") as queue:
            for index in range(5):
                bus.publish(JobEvent(event="progress", data={"index": index}), job_id="job-1")
            events = [await asyncio.wait_for(queue.get(), timeout=1) for _ in range(2)]
            return [str(event.data["index"]) for event in events]

    assert asyncio.run(scenario()) == ["3", "4"]
