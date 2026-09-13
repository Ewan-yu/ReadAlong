from __future__ import annotations

from fastapi import Request

from app.jobs.events import EventBus
from app.jobs.manager import JobManager
from app.models.errors import PipelineError
from app.pipeline.state_repository import StateRepository
from app.services.page_workspace_service import PageWorkspaceService
from app.services.proofread_workspace_service import ProofreadWorkspaceService
from app.services.audio_workspace_service import AudioWorkspaceService
from app.services.export_workspace_service import ExportWorkspaceService
from app.services.workspace_service import WorkspaceService
from app.services.workspace_catalog_service import WorkspaceCatalogService
from app.services.workspace_migration_service import WorkspaceMigrationService
from app.services.voice_profile_service import VoiceProfileService
from app.services.original_audio_review_service import OriginalAudioReviewService
from app.services.timeline_workspace_service import TimelineWorkspaceService


def get_job_manager(request: Request) -> JobManager:
    return request.app.state.job_manager


def require_migration_idle(request: Request) -> None:
    """Reject direct workspace/voice writes while storage migrates.

    Pipeline jobs are already held by the JobManager maintenance slot, but
    synchronous routes (book creation, review decisions, voice profiles)
    write straight to the data root; during a migration those writes only
    reach the old root and would be deleted by the post-restart cleanup.
    """
    service = getattr(request.app.state, "workspace_migration_service", None)
    if service is not None and service.barrier_active():
        raise PipelineError(
            "MIGRATION_IN_PROGRESS",
            "正在迁移数据目录；请等待迁移完成并重启家长端后再继续制作。",
            status_code=409,
        )


def get_state_repository(request: Request) -> StateRepository:
    return request.app.state.state_repository


def get_event_bus(request: Request) -> EventBus:
    return request.app.state.event_bus


def get_workspace_service(request: Request) -> WorkspaceService:
    return request.app.state.workspace_service


def get_workspace_catalog_service(request: Request) -> WorkspaceCatalogService:
    return request.app.state.workspace_catalog_service


def get_workspace_migration_service(request: Request) -> WorkspaceMigrationService:
    return request.app.state.workspace_migration_service


def get_voice_profile_service(request: Request) -> VoiceProfileService:
    return request.app.state.voice_profile_service


def get_page_workspace_service(request: Request) -> PageWorkspaceService:
    return request.app.state.page_workspace_service


def get_proofread_workspace_service(request: Request) -> ProofreadWorkspaceService:
    return request.app.state.proofread_workspace_service


def get_audio_workspace_service(request: Request) -> AudioWorkspaceService:
    return request.app.state.audio_workspace_service


def get_export_workspace_service(request: Request) -> ExportWorkspaceService:
    return request.app.state.export_workspace_service


def get_original_audio_review_service(request: Request) -> OriginalAudioReviewService:
    return request.app.state.original_audio_review_service


def get_timeline_workspace_service(request: Request) -> TimelineWorkspaceService:
    return request.app.state.timeline_workspace_service
