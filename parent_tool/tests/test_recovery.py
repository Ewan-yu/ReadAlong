from pathlib import Path

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
