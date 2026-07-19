import time
from io import BytesIO
from pathlib import Path
from threading import Event, Timer

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import BaseModel, ConfigDict

from app.config import Settings
from app.main import SpaStaticFiles, create_app
from app.models.jobs import JobStatus
from app.models.pipeline import PipelineState, StepId, StepResult
from app.pipeline.definitions import StepRegistry
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.pipeline.steps.pages import PageProcessingStep


def _pdf_upload() -> bytes:
    import fitz

    document = fitz.open()
    try:
        page = document.new_page(width=300, height=400)
        page.insert_text((40, 50), "ReadAlong")
        return document.tobytes()
    finally:
        document.close()


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


def test_create_book_uploads_pdf_into_new_workspace(tmp_path: Path) -> None:
    with _client(tmp_path) as client:
        response = client.post(
            "/api/books",
            files={"pdf": ("My Granny.pdf", BytesIO(_pdf_upload()), "application/pdf")},
        )

    assert response.status_code == 201
    state = response.json()
    assert state["book_id"].startswith("my-granny-")
    assert state["source"]["pdf_path"] == "source.pdf"
    assert (tmp_path / state["book_id"] / "source.pdf").is_file()
    metadata = (tmp_path / state["book_id"] / "workspace.json").read_text(encoding="utf-8")
    assert '"display_name":"My Granny"' in metadata


def test_workspace_catalog_lists_storage_and_deletes_project(tmp_path: Path) -> None:
    with _client(tmp_path) as client:
        listing = client.get("/api/books")
        storage = client.get("/api/storage")
        deleted = client.delete("/api/books/book-1")
        missing = client.get("/api/books/book-1/state")

    assert listing.status_code == 200
    assert listing.json()["workspaces"][0]["book_id"] == "book-1"
    assert listing.json()["workspaces"][0]["continue_path"] == "/books/book-1/pages"
    assert storage.status_code == 200
    assert storage.json()["workspace_count"] == 1
    assert Path(storage.json()["workspace_root"]) == tmp_path
    assert deleted.status_code == 204
    assert missing.status_code == 404


def test_workspace_delete_is_rejected_while_job_is_active(tmp_path: Path) -> None:
    class BlockingStep(ApiFakeStep):
        def __init__(self) -> None:
            self.started = Event()
            self.release = Event()

        def run(self, context, params):
            self.started.set()
            assert self.release.wait(2)
            (context.staging_dir / "result.txt").write_text(params.value, encoding="utf-8")
            return StepResult(outputs=("result.txt",))

    step = BlockingStep()
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
        try:
            response = client.delete("/api/books/book-1")
        finally:
            step.release.set()
        _wait_for_terminal(client, started.json()["job_id"])

    assert response.status_code == 409
    assert response.json()["code"] == "WORKSPACE_BUSY"
    assert paths.book("book-1").is_dir()


def test_create_book_preserves_optional_original_audio(tmp_path: Path) -> None:
    audio = b"ID3" + b"\x00" * 32
    with _client(tmp_path) as client:
        response = client.post(
            "/api/books",
            files={
                "pdf": ("My Granny.pdf", BytesIO(_pdf_upload()), "application/pdf"),
                "original_audio": ("narration.mp3", BytesIO(audio), "audio/mpeg"),
            },
        )

    assert response.status_code == 201
    state = response.json()
    assert state["source"]["original_audio_path"] == "original_audio.mp3"
    assert len(state["source"]["original_audio_sha256"]) == 64
    assert (tmp_path / state["book_id"] / "original_audio.mp3").read_bytes() == audio


def test_create_book_rejects_non_mp3_original_audio(tmp_path: Path) -> None:
    with _client(tmp_path) as client:
        response = client.post(
            "/api/books",
            files={
                "pdf": ("book.pdf", BytesIO(_pdf_upload()), "application/pdf"),
                "original_audio": ("narration.wav", BytesIO(b"RIFF"), "audio/wav"),
            },
        )

    assert response.status_code == 422
    assert response.json()["code"] == "ORIGINAL_AUDIO_INVALID"


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


def test_lifespan_releases_instance_lock_when_setup_fails(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import app.main as main_module

    class FakeLock:
        released = False

        def acquire(self):
            return self

        def release(self):
            self.released = True

    lock = FakeLock()
    monkeypatch.setattr(main_module.portalocker, "Lock", lambda *_args, **_kwargs: lock)
    app = create_app(
        settings=Settings(workspace_root=tmp_path),
        executor_factory=lambda: (_ for _ in ()).throw(RuntimeError("executor failed")),
    )

    with pytest.raises(RuntimeError, match="executor failed"):
        with TestClient(app):
            pass

    assert lock.released is True


def test_openapi_contains_typed_pipeline_paths(tmp_path: Path) -> None:
    with _client(tmp_path) as client:
        schema = client.get("/openapi.json").json()

    paths = schema["paths"]
    assert "/api/books/{book_id}/state" in paths
    assert "/api/books" in paths
    assert "/api/books/{book_id}" in paths
    assert "/api/books/{book_id}/summary" in paths
    assert "/api/storage" in paths
    assert "/api/storage/recalculate" in paths
    assert "/api/storage/migrations" in paths
    assert "/api/storage/migrations/{migration_id}" in paths
    assert "/api/voices" in paths
    assert "/api/voices/{voice_id}/preview" in paths
    assert "/api/books/{book_id}/steps/{step_id}/run" in paths
    assert "/api/jobs/{job_id}" in paths
    assert "/api/jobs/{job_id}/events" in paths
    assert "/api/jobs/{job_id}/cancel" in paths
    assert "/api/capabilities" in paths
    assert "/api/books/{book_id}/pages/workspace" in paths
    assert "/api/books/{book_id}/pages/source/{source_pdf_page}.webp" in paths
    assert "/api/books/{book_id}/pages/revisions/{revision_id}/assets/{asset_path}" in paths
    assert "PipelineState" in schema["components"]["schemas"]
    assert "JobSnapshot" in schema["components"]["schemas"]
    assert "ApiErrorResponse" in schema["components"]["schemas"]
    assert "CapabilitiesResponse" in schema["components"]["schemas"]
    assert "PageWorkspaceResponse" in schema["components"]["schemas"]
    run_responses = paths["/api/books/{book_id}/steps/{step_id}/run"]["post"]["responses"]
    assert "200" in run_responses
    assert "202" in run_responses


def test_spa_static_files_only_falls_back_for_client_routes(tmp_path: Path) -> None:
    web_dist = tmp_path / "web-dist"
    web_dist.mkdir()
    (web_dist / "index.html").write_text("<main>ReadAlong</main>", encoding="utf-8")

    static_app = FastAPI()
    static_app.mount("/", SpaStaticFiles(directory=web_dist, html=True), name="web")

    with TestClient(static_app) as client:
        deep_link = client.get("/books/book-1/pages")
        missing_asset = client.get("/assets/missing.js")
        missing_api = client.get("/api/missing")

    assert deep_link.status_code == 200
    assert "ReadAlong" in deep_link.text
    assert missing_asset.status_code == 404
    assert missing_api.status_code == 404


def test_page_workspace_exposes_plan_preview_and_declared_assets(tmp_path: Path) -> None:
    app = create_app(
        settings=Settings(workspace_root=tmp_path),
        step_registry=StepRegistry((PageProcessingStep(),)),
    )
    with TestClient(app) as client:
        created = client.post(
            "/api/books",
            files={"pdf": ("Preview Book.pdf", BytesIO(_pdf_upload()), "application/pdf")},
        ).json()
        book_id = created["book_id"]
        started = client.post(
            f"/api/books/{book_id}/steps/pages/run",
            json={
                "params": {
                    "reading_long_edge": 800,
                    "ocr_dpi": 150,
                    "detection_dpi": 48,
                    "thumbnail_long_edge": 120,
                }
            },
        )
        assert started.status_code == 202
        assert _wait_for_terminal(client, started.json()["job_id"])["status"] == "succeeded"

        workspace = client.get(f"/api/books/{book_id}/pages/workspace")
        body = workspace.json()
        preview = client.get(f"/api/books/{book_id}/pages/source/1.webp?max_edge=240")
        thumbnail_path = body["plan"]["pages"][0]["outputs"][0]["thumbnail"]
        asset = client.get(
            f"/api/books/{book_id}/pages/revisions/{body['revision_id']}/assets/{thumbnail_path}"
        )
        undeclared = client.get(
            f"/api/books/{book_id}/pages/revisions/{body['revision_id']}/assets/page_plan.json"
        )

    assert workspace.status_code == 200
    assert body["plan"]["source_pdf_page_count"] == 1
    assert body["sentences"] == []
    assert preview.status_code == 200
    assert preview.headers["content-type"] == "image/webp"
    assert asset.status_code == 200
    assert asset.headers["content-type"] == "image/jpeg"
    assert undeclared.status_code == 404
    assert undeclared.json()["code"] == "PAGE_ASSET_NOT_FOUND"
