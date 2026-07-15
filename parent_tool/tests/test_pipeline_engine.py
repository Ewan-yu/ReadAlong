from pathlib import Path

import pytest
from pydantic import BaseModel, ConfigDict

from app.models.errors import PipelineError
from app.models.pipeline import PipelineState, StepId, StepStatus, StepResult
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import CancellationToken, StepRegistry
from app.pipeline.engine import PipelineEngine, SkippedRun
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository


class FakeParams(BaseModel):
    model_config = ConfigDict(extra="forbid")

    value: str
    fail: bool = False


class FakeStep:
    def __init__(self, step_id: StepId, version: str = "test-v1") -> None:
        self.step_id = step_id
        self.implementation_version = version
        self.params_model = FakeParams

    def run(self, context, params):
        context.cancellation.raise_if_cancelled()
        if params.fail:
            raise RuntimeError("synthetic failure")
        (context.staging_dir / "result.txt").write_text(params.value, encoding="utf-8")
        context.progress(1.0, "done")
        return StepResult(outputs=("result.txt",))


def _engine(tmp_path: Path, *steps: FakeStep) -> tuple[PipelineEngine, StateRepository]:
    paths = WorkspacePaths(tmp_path)
    repository = StateRepository(paths)
    repository.create(
        PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64)
    )
    return (
        PipelineEngine(repository, ArtifactStore(paths), StepRegistry(tuple(steps))),
        repository,
    )


def _run(engine: PipelineEngine, step_id: StepId, value: str, *, job: str):
    plan = engine.plan("book-1", step_id, {"value": value})
    assert not isinstance(plan, SkippedRun)
    prepared = engine.begin(plan, job)
    return engine.execute(prepared, lambda _progress, _message: None, CancellationToken())


def test_first_run_publishes_done_revision(tmp_path: Path) -> None:
    engine, repository = _engine(tmp_path, FakeStep(StepId.PAGES))

    success = _run(
        engine,
        StepId.PAGES,
        "first",
        job="12345678-1234-4234-8234-123456789abc",
    )

    state = repository.load("book-1")
    assert state.steps[StepId.PAGES].status is StepStatus.DONE
    assert state.steps[StepId.PAGES].success == success
    assert (tmp_path / "book-1" / success.output_root / "result.txt").read_text() == "first"


def test_identical_valid_run_is_skipped(tmp_path: Path) -> None:
    engine, _ = _engine(tmp_path, FakeStep(StepId.PAGES))
    _run(engine, StepId.PAGES, "first", job="12345678-1234-4234-8234-123456789abc")

    decision = engine.plan("book-1", StepId.PAGES, {"value": "first"})

    assert isinstance(decision, SkippedRun)


def test_tampered_output_is_not_skipped(tmp_path: Path) -> None:
    engine, repository = _engine(tmp_path, FakeStep(StepId.PAGES))
    success = _run(
        engine,
        StepId.PAGES,
        "first",
        job="12345678-1234-4234-8234-123456789abc",
    )
    (tmp_path / "book-1" / success.output_root / "result.txt").write_text(
        "tampered", encoding="utf-8"
    )

    assert not isinstance(engine.plan("book-1", StepId.PAGES, {"value": "first"}), SkippedRun)
    assert repository.load("book-1").steps[StepId.PAGES].status is StepStatus.FAILED


def test_dependency_must_be_done(tmp_path: Path) -> None:
    engine, _ = _engine(tmp_path, FakeStep(StepId.OCR))

    with pytest.raises(PipelineError) as caught:
        engine.plan("book-1", StepId.OCR, {"value": "ocr"})

    assert caught.value.code == "STEP_DEPENDENCY_NOT_READY"


def test_cancelled_run_does_not_publish(tmp_path: Path) -> None:
    engine, repository = _engine(tmp_path, FakeStep(StepId.PAGES))
    plan = engine.plan("book-1", StepId.PAGES, {"value": "first"})
    assert not isinstance(plan, SkippedRun)
    prepared = engine.begin(plan, "12345678-1234-4234-8234-123456789abc")
    token = CancellationToken()
    token.request()

    with pytest.raises(PipelineError) as caught:
        engine.execute(prepared, lambda _progress, _message: None, token)

    assert caught.value.code == "JOB_CANCELLED"
    state = repository.load("book-1")
    assert state.steps[StepId.PAGES].status is StepStatus.FAILED
    assert state.steps[StepId.PAGES].success is None
    assert not (tmp_path / "book-1" / "01_pages" / "revisions").exists()


def test_failed_rerun_preserves_old_success(tmp_path: Path) -> None:
    engine, repository = _engine(tmp_path, FakeStep(StepId.PAGES))
    first = _run(
        engine,
        StepId.PAGES,
        "first",
        job="12345678-1234-4234-8234-123456789abc",
    )
    plan = engine.plan("book-1", StepId.PAGES, {"value": "second", "fail": True})
    assert not isinstance(plan, SkippedRun)
    prepared = engine.begin(plan, "22345678-1234-4234-8234-123456789abc")

    with pytest.raises(RuntimeError, match="synthetic failure"):
        engine.execute(prepared, lambda _progress, _message: None, CancellationToken())

    state = repository.load("book-1")
    assert state.steps[StepId.PAGES].status is StepStatus.DONE
    assert state.steps[StepId.PAGES].success == first


def test_successful_upstream_rerun_stales_completed_downstream(tmp_path: Path) -> None:
    engine, repository = _engine(
        tmp_path,
        FakeStep(StepId.PAGES),
        FakeStep(StepId.OCR),
    )
    _run(engine, StepId.PAGES, "pages-v1", job="12345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.OCR, "ocr-v1", job="22345678-1234-4234-8234-123456789abc")

    _run(engine, StepId.PAGES, "pages-v2", job="32345678-1234-4234-8234-123456789abc")

    state = repository.load("book-1")
    assert state.steps[StepId.PAGES].status is StepStatus.DONE
    assert state.steps[StepId.OCR].status is StepStatus.STALE
    assert state.steps[StepId.OCR].stale_reason is not None
    assert state.steps[StepId.OCR].stale_reason.source_step is StepId.PAGES


def test_cleanup_failure_does_not_rollback_committed_success(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    engine, repository = _engine(tmp_path, FakeStep(StepId.PAGES))

    def fail_cleanup(_state) -> None:
        raise OSError("cleanup unavailable")

    monkeypatch.setattr(engine.artifacts, "cleanup_unreferenced", fail_cleanup)

    success = _run(
        engine,
        StepId.PAGES,
        "first",
        job="12345678-1234-4234-8234-123456789abc",
    )

    state = repository.load("book-1")
    assert state.steps[StepId.PAGES].status is StepStatus.DONE
    assert state.steps[StepId.PAGES].success == success
    assert (tmp_path / "book-1" / success.output_root / "result.txt").is_file()
