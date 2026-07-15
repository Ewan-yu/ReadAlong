from pathlib import Path

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.models.pipeline import (
    ActiveAttempt,
    AttemptStatus,
    PipelineState,
    StepId,
    StepState,
    StepStatus,
    utc_now,
)
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository


def _running_step(base_status: StepStatus) -> StepState:
    return StepState(
        status=StepStatus.RUNNING,
        active_attempt=ActiveAttempt(
            job_id="12345678-1234-4234-8234-123456789abc",
            params_hash="a" * 64,
            input_fingerprint="b" * 64,
            base_status=base_status,
            started_at=utc_now(),
        ),
    )


def test_recover_interrupted_attempt_without_success_becomes_failed(tmp_path: Path) -> None:
    repository = StateRepository(WorkspacePaths(tmp_path))
    state = PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64)
    state.steps[StepId.PAGES] = _running_step(StepStatus.PENDING)
    repository.create(state)

    recovered = repository.recover_interrupted("book-1")
    page_step = recovered.steps[StepId.PAGES]

    assert page_step.status is StepStatus.FAILED
    assert page_step.active_attempt is None
    assert page_step.last_attempt is not None
    assert page_step.last_attempt.status is AttemptStatus.INTERRUPTED
    assert page_step.last_attempt.error is not None
    assert page_step.last_attempt.error.code == "PROCESS_INTERRUPTED"


def test_recovery_is_idempotent(tmp_path: Path) -> None:
    repository = StateRepository(WorkspacePaths(tmp_path))
    state = PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64)
    state.steps[StepId.PAGES] = _running_step(StepStatus.PENDING)
    repository.create(state)

    first = repository.recover_interrupted("book-1")
    second = repository.recover_interrupted("book-1")

    assert second == first
    assert second.revision == 1


def test_startup_isolates_corrupt_files_and_cleans_abandoned_artifacts(
    tmp_path: Path,
) -> None:
    paths = WorkspacePaths(tmp_path)
    repository = StateRepository(paths)
    repository.create(
        PipelineState.new(book_id="healthy", pdf_path="source.pdf", pdf_sha256="a" * 64)
    )
    repository.create(
        PipelineState.new(book_id="broken", pdf_path="source.pdf", pdf_sha256="b" * 64)
    )
    (tmp_path / "broken" / "state.json").write_text("{broken", encoding="utf-8")
    abandoned_run = (
        tmp_path / "healthy" / ".runs" / "12345678-1234-4234-8234-123456789abc"
    )
    abandoned_run.mkdir(parents=True)
    (abandoned_run / "partial.txt").write_text("partial", encoding="utf-8")
    abandoned_revision = (
        tmp_path / "healthy" / "01_pages" / "revisions" / "r-deadbeef-12345678"
    )
    abandoned_revision.mkdir(parents=True)
    (abandoned_revision / "old.txt").write_text("old", encoding="utf-8")
    paths.jobs.mkdir(parents=True)
    corrupt_job = paths.jobs / "22345678-1234-4234-8234-123456789abc.json"
    corrupt_job.write_text("{broken", encoding="utf-8")

    app = create_app(settings=Settings(workspace_root=tmp_path))
    with TestClient(app) as client:
        assert client.get("/api/books/healthy/state").status_code == 200
        broken = client.get("/api/books/broken/state")
        assert broken.status_code == 500
        assert broken.json()["code"] == "WORKSPACE_STATE_CORRUPT"

    assert not abandoned_run.exists()
    assert not abandoned_revision.exists()
    assert corrupt_job.read_text(encoding="utf-8") == "{broken"
