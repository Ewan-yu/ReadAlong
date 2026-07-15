from pathlib import Path

import pytest
from pydantic import ValidationError

from app.models.pipeline import (
    ActiveAttempt,
    OutputFile,
    PipelineState,
    StepState,
    StepStatus,
    StepSuccess,
    utc_now,
)
from app.pipeline.paths import WorkspacePaths
from app.models.errors import PipelineError


def _success() -> StepSuccess:
    return StepSuccess(
        revision_id="r-abc123-job12345",
        output_root="01_pages/revisions/r-abc123-job12345",
        params_hash="a" * 64,
        input_fingerprint="b" * 64,
        output_fingerprint="c" * 64,
        outputs=(OutputFile(path="result.json", size=2, sha256="d" * 64),),
        completed_at=utc_now(),
    )


def _attempt(base_status: StepStatus = StepStatus.PENDING) -> ActiveAttempt:
    return ActiveAttempt(
        job_id="12345678-1234-4234-8234-123456789abc",
        params_hash="a" * 64,
        input_fingerprint="b" * 64,
        base_status=base_status,
        started_at=utc_now(),
    )


def test_new_pipeline_has_all_pending_steps() -> None:
    state = PipelineState.new(
        book_id="book-1",
        pdf_path="source.pdf",
        pdf_sha256="a" * 64,
    )

    assert state.schema_version == 1
    assert state.revision == 0
    assert set(state.steps) == {"pages", "ocr", "proofread", "audio", "export"}
    assert {step.status for step in state.steps.values()} == {StepStatus.PENDING}


def test_running_step_requires_active_attempt() -> None:
    with pytest.raises(ValidationError):
        StepState(status=StepStatus.RUNNING)


def test_non_running_step_rejects_active_attempt() -> None:
    with pytest.raises(ValidationError):
        StepState(status=StepStatus.PENDING, active_attempt=_attempt())


def test_done_and_stale_steps_require_success() -> None:
    for status in (StepStatus.DONE, StepStatus.STALE):
        with pytest.raises(ValidationError):
            StepState(status=status)


def test_running_step_may_retain_previous_success() -> None:
    step = StepState(
        status=StepStatus.RUNNING,
        success=_success(),
        active_attempt=_attempt(StepStatus.DONE),
    )

    assert step.active_attempt is not None
    assert step.success is not None


def test_workspace_paths_reject_book_traversal(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path)

    with pytest.raises(PipelineError) as caught:
        paths.book("../outside")

    assert caught.value.code == "WORKSPACE_PATH_INVALID"


def test_workspace_paths_keep_books_under_root(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path)

    assert paths.book("book-1") == (tmp_path / "book-1").resolve()
