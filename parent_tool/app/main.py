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

from app.api.errors import install_error_handlers
from app.api.routes.jobs import router as jobs_router
from app.api.routes.pipeline import router as pipeline_router
from app.config import Settings
from app.jobs.events import EventBus
from app.jobs.manager import JobManager
from app.jobs.repository import JobRepository
from app.models.errors import PipelineError
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import StepRegistry
from app.pipeline.engine import PipelineEngine
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.pipeline.steps import OcrStep, PageProcessingStep
from app.providers.ocr import PaddleOcrProvider
from app.services.workspace_service import WorkspaceService


ExecutorFactory = Callable[[], ThreadPoolExecutor]


def create_app(
    *,
    settings: Settings | None = None,
    step_registry: StepRegistry | None = None,
    executor_factory: ExecutorFactory | None = None,
) -> FastAPI:
    resolved_settings = settings or Settings.from_environment()
    registry = step_registry or StepRegistry((PageProcessingStep(), OcrStep(PaddleOcrProvider())))
    make_executor = executor_factory or (
        lambda: ThreadPoolExecutor(max_workers=1, thread_name_prefix="readalong-pipeline")
    )

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        paths = WorkspacePaths(resolved_settings.workspace_root)
        paths.engine.mkdir(parents=True, exist_ok=True)
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

    web_dist = Path(__file__).parent.parent / "web" / "dist"
    if web_dist.exists():
        application.mount("/", StaticFiles(directory=web_dist, html=True), name="web")
    return application


app = create_app()


def run() -> None:
    import uvicorn

    webbrowser.open("http://127.0.0.1:8760")
    uvicorn.run(app, host="127.0.0.1", port=8760)


if __name__ == "__main__":
    run()
