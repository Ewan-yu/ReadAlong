# -*- coding: utf-8 -*-
"""ReadAlong parent service: FastAPI API plus the built local SPA."""

from __future__ import annotations

import webbrowser
from collections.abc import AsyncIterator
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Callable

import portalocker
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHttpException
from starlette.responses import Response

from app.api.errors import install_error_handlers
from app.api.routes.jobs import router as jobs_router
from app.api.routes.pages import router as pages_router
from app.api.routes.proofread import router as proofread_router
from app.api.routes.audio import router as audio_router
from app.api.routes.exports import router as export_router
from app.api.routes.pipeline import router as pipeline_router
from app.api.routes.system import router as system_router
from app.config import Settings, UserSettingsStore
from app.jobs.events import EventBus
from app.jobs.manager import JobManager
from app.jobs.repository import JobRepository
from app.models.errors import PipelineError
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import StepRegistry
from app.pipeline.engine import PipelineEngine
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.pipeline.steps import AudioStep, AutoProofreadStep, ExportStep, OcrStep, PageProcessingStep
from app.providers.align import StableTsWordAligner
from app.providers.ocr import PaddleOcrProvider
from app.providers.tts import FfmpegOpusTranscoder, VoxCpmTtsProvider
from app.services.workspace_service import WorkspaceService
from app.services.workspace_catalog_service import WorkspaceCatalogService
from app.services.workspace_migration_service import WorkspaceMigrationService
from app.services.page_workspace_service import PageWorkspaceService
from app.services.proofread_workspace_service import ProofreadWorkspaceService
from app.services.audio_workspace_service import AudioWorkspaceService
from app.services.export_workspace_service import ExportWorkspaceService


ExecutorFactory = Callable[[], ThreadPoolExecutor]


class SpaStaticFiles(StaticFiles):
    """Serve Vite assets and fall back to index.html for client-side routes."""

    async def get_response(self, path: str, scope: dict) -> Response:
        try:
            return await super().get_response(path, scope)
        except StarletteHttpException as exc:
            request_path = str(scope.get("path", "")).lstrip("/")
            if (
                exc.status_code != 404
                or request_path == "api"
                or request_path.startswith("api/")
                or "." in Path(request_path).name
            ):
                raise
            return await super().get_response("index.html", scope)


def create_app(
    *,
    settings: Settings | None = None,
    step_registry: StepRegistry | None = None,
    executor_factory: ExecutorFactory | None = None,
) -> FastAPI:
    resolved_settings = settings or Settings.from_environment()
    registry = step_registry or StepRegistry(
        (
            PageProcessingStep(),
            OcrStep(PaddleOcrProvider()),
            AutoProofreadStep(),
            AudioStep(
                VoxCpmTtsProvider(),
                StableTsWordAligner(),
                FfmpegOpusTranscoder(),
            ),
            ExportStep(),
        )
    )
    make_executor = executor_factory or (
        lambda: ThreadPoolExecutor(max_workers=1, thread_name_prefix="readalong-pipeline")
    )

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        paths = WorkspacePaths(resolved_settings.workspace_root)
        paths.engine.mkdir(parents=True, exist_ok=True)
        settings_store = UserSettingsStore(resolved_settings.settings_path)
        instance_lock = portalocker.Lock(str(paths.instance_lock), mode="a+", timeout=0)
        try:
            instance_lock.acquire()
        except portalocker.exceptions.LockException as exc:
            raise RuntimeError("另一个 ReadAlong 家长端实例正在使用该工作区。") from exc
        manager: JobManager | None = None
        try:
            states = StateRepository(paths)
            artifacts = ArtifactStore(paths)
            jobs = JobRepository(paths)
            events = EventBus()
            engine = PipelineEngine(states, artifacts, registry)
            manager = JobManager(engine, jobs, events, executor=make_executor())
            workspace_service = WorkspaceService(paths, states)
            workspace_catalog_service = WorkspaceCatalogService(paths, states, manager, resolved_settings)
            workspace_catalog_service.cleanup_trash()
            manager.recover()
            for book_id in states.list_books():
                try:
                    state = states.recover_interrupted(book_id)
                    artifacts.cleanup_abandoned_staging(book_id)
                    artifacts.cleanup_unreferenced(state)
                except PipelineError:
                    continue
            application.state.settings = resolved_settings
            application.state.state_repository = states
            application.state.artifact_store = artifacts
            application.state.job_repository = jobs
            application.state.event_bus = events
            application.state.pipeline_engine = engine
            application.state.job_manager = manager
            application.state.workspace_service = workspace_service
            application.state.workspace_catalog_service = workspace_catalog_service
            application.state.workspace_migration_service = WorkspaceMigrationService(
                paths, manager, resolved_settings, settings_store
            )
            application.state.page_workspace_service = PageWorkspaceService(paths, states, artifacts)
            application.state.proofread_workspace_service = ProofreadWorkspaceService(paths, states, artifacts)
            application.state.audio_workspace_service = AudioWorkspaceService(paths, states, artifacts)
            application.state.export_workspace_service = ExportWorkspaceService(paths, states, artifacts)
            WorkspaceMigrationService.cleanup_pending_source(resolved_settings, settings_store)
            yield
        finally:
            if manager is not None:
                manager.shutdown()
            instance_lock.release()

    application = FastAPI(
        title="ReadAlong Parent Tool",
        version="0.1.0",
        lifespan=lifespan,
    )
    install_error_handlers(application)

    @application.get("/api/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "version": "0.1.0"}

    application.include_router(pipeline_router)
    application.include_router(jobs_router)
    application.include_router(pages_router)
    application.include_router(proofread_router)
    application.include_router(audio_router)
    application.include_router(export_router)
    application.include_router(system_router)

    web_dist = Path(__file__).parent.parent / "web" / "dist"
    if web_dist.exists():
        application.mount("/", SpaStaticFiles(directory=web_dist, html=True), name="web")
    return application


app = create_app()


def run() -> None:
    import uvicorn

    webbrowser.open("http://127.0.0.1:8760")
    uvicorn.run(app, host="127.0.0.1", port=8760)


if __name__ == "__main__":
    run()
