import time
from pathlib import Path
from threading import Event, Timer

import pytest
from fastapi.testclient import TestClient
from pydantic import BaseModel, ConfigDict

from app.config import Settings
from app.main import create_app
from app.models.jobs import JobStatus
from app.models.pipeline import PipelineState, StepId, StepResult
from app.pipeline.definitions import StepRegistry
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository


class ApiParams(BaseModel):
    model_config = ConfigDict(extra="forbid")

    value: str


class ApiFakeStep:
    step_id = StepId.PAGES
    implementation_version = "api-test-v1"
    params_model = ApiParams

    def run(self, context, params):
        context.progress(0.5, "half")
        (context.staging_dir / "result.txt").write_text(params.value, encoding="utf-8")
        return StepResult(outputs=("result.txt",))


def _client(tmp_path: Path) -> TestClient:
    paths = WorkspacePaths(tmp_path)
    StateRepository(paths).create(
        PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64)
    )
    app = create_app(
        settings=Settings(workspace_root=tmp_path),
        step_registry=StepRegistry((ApiFakeStep(),)),
    )
    return TestClient(app)


def _wait_for_terminal(client: TestClient, job_id: str) -> dict:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        body = client.get(f"/api/jobs/{job_id}").json()
        if body["status"] in {status.value for status in JobStatus if status.terminal}:
            return body
        time.sleep(0.01)
    raise AssertionError("job did not finish")


def test_run_step_exposes_job_and_state(tmp_path: Path) -> None:
    with _client(tmp_path) as client:
        response = client.post(
            "/api/books/book-1/steps/pages/run",
            json={"params": {"value": "hello"}},
        )

        assert response.status_code == 202
        assert response.json()["disposition"] == "started"
        job = _wait_for_terminal(client, response.json()["job_id"])
        assert job["status"] == "succeeded"
        state = client.get("/api/books/book-1/state").json()
        assert state["steps"]["pages"]["status"] == "done"


def test_identical_step_request_returns_skipped(tmp_path: Path) -> None:
    with _client(tmp_path) as client:
        first = client.post(
            "/api/books/book-1/steps/pages/run",
            json={"params": {"value": "hello"}},
        )
        _wait_for_terminal(client, first.json()["job_id"])

        skipped = client.post(
            "/api/books/book-1/steps/pages/run",
            json={"params": {"value": "hello"}},
        )

        assert skipped.status_code == 200
        assert skipped.json()["disposition"] == "skipped"


def test_api_uses_structured_not_found_and_validation_errors(tmp_path: Path) -> None:
    with _client(tmp_path) as client:
        missing = client.get("/api/books/missing/state")
        invalid = client.post(
            "/api/books/book-1/steps/pages/run",
            json={"params": {"unknown": "field"}},
        )
        invalid_step = client.post(
            "/api/books/book-1/steps/not-a-step/run",
            json={"params": {}},
        )

        assert missing.status_code == 404
        assert missing.json()["code"] == "BOOK_NOT_FOUND"
        assert missing.json()["request_id"]
        assert invalid.status_code == 422
        assert invalid.json()["code"] == "INVALID_STEP_PARAMS"
        assert invalid.json()["request_id"]
        assert invalid_step.status_code == 422
        assert invalid_step.json()["code"] == "INVALID_STEP_PARAMS"
        assert invalid_step.json()["request_id"]


def test_dependency_error_is_conflict(tmp_path: Path) -> None:
    class OcrStep(ApiFakeStep):
        step_id = StepId.OCR

    paths = WorkspacePaths(tmp_path)
    StateRepository(paths).create(
        PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64)
    )
    app = create_app(
        settings=Settings(workspace_root=tmp_path),
        step_registry=StepRegistry((OcrStep(),)),
    )

    with TestClient(app) as client:
        response = client.post(
            "/api/books/book-1/steps/ocr/run",
            json={"params": {"value": "ocr"}},
        )

    assert response.status_code == 409
    assert response.json()["code"] == "STEP_DEPENDENCY_NOT_READY"


def test_sse_starts_with_current_snapshot(tmp_path: Path) -> None:
    with _client(tmp_path) as client:
        started = client.post(
            "/api/books/book-1/steps/pages/run",
            json={"params": {"value": "hello"}},
        )
        job_id = started.json()["job_id"]
        _wait_for_terminal(client, job_id)

        with client.stream("GET", f"/api/jobs/{job_id}/events") as response:
            lines = [line for line in response.iter_lines() if line]

        assert response.status_code == 200
        assert lines[0] == "event: snapshot"
        assert lines[1].startswith("data: ")
        assert '"status":"succeeded"' in lines[1]


def test_active_sse_stream_includes_progress_and_terminal(tmp_path: Path) -> None:
    class StreamingStep(ApiFakeStep):
        def __init__(self) -> None:
            self.started = Event()
            self.release = Event()

        def run(self, context, params):
            self.started.set()
            assert self.release.wait(2)
            context.progress(0.75, "almost")
            (context.staging_dir / "result.txt").write_text(params.value, encoding="utf-8")
            return StepResult(outputs=("result.txt",))

    step = StreamingStep()
    paths = WorkspacePaths(tmp_path)
    StateRepository(paths).create(
        PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64)
    )
    app = create_app(
        settings=Settings(workspace_root=tmp_path),
        step_registry=StepRegistry((step,)),
    )
    with TestClient(app) as client:
        started = client.post(
            "/api/books/book-1/steps/pages/run",
            json={"params": {"value": "hello"}},
        )
        assert step.started.wait(1)
        timer = Timer(0.1, step.release.set)
        timer.start()
        try:
            with client.stream("GET", f"/api/jobs/{started.json()['job_id']}/events") as response:
                lines = [line for line in response.iter_lines() if line.startswith("event: ")]
        finally:
            timer.cancel()
            step.release.set()

    assert response.status_code == 200
    assert lines[0] == "event: snapshot"
    assert "event: progress" in lines
    assert lines[-1] == "event: succeeded"


def test_second_app_instance_cannot_share_workspace(tmp_path: Path) -> None:
    first = create_app(settings=Settings(workspace_root=tmp_path))
    second = create_app(settings=Settings(workspace_root=tmp_path))

    with TestClient(first):
        with pytest.raises(RuntimeError, match="另一个 ReadAlong"):
            with TestClient(second):
                pass


def test_openapi_contains_typed_pipeline_paths(tmp_path: Path) -> None:
    with _client(tmp_path) as client:
        schema = client.get("/openapi.json").json()

    paths = schema["paths"]
    assert "/api/books/{book_id}/state" in paths
    assert "/api/books/{book_id}/steps/{step_id}/run" in paths
    assert "/api/jobs/{job_id}" in paths
    assert "/api/jobs/{job_id}/events" in paths
    assert "/api/jobs/{job_id}/cancel" in paths
    assert "PipelineState" in schema["components"]["schemas"]
    assert "JobSnapshot" in schema["components"]["schemas"]
    assert "ApiErrorResponse" in schema["components"]["schemas"]
    run_responses = paths["/api/books/{book_id}/steps/{step_id}/run"]["post"]["responses"]
    assert "200" in run_responses
    assert "202" in run_responses
