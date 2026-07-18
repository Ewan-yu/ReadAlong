from __future__ import annotations

from fastapi import Request

from app.jobs.events import EventBus
from app.jobs.manager import JobManager
from app.pipeline.state_repository import StateRepository
from app.services.page_workspace_service import PageWorkspaceService
from app.services.proofread_workspace_service import ProofreadWorkspaceService
from app.services.audio_workspace_service import AudioWorkspaceService
from app.services.export_workspace_service import ExportWorkspaceService
from app.services.workspace_service import WorkspaceService


def get_job_manager(request: Request) -> JobManager:
    return request.app.state.job_manager


def get_state_repository(request: Request) -> StateRepository:
    return request.app.state.state_repository


def get_event_bus(request: Request) -> EventBus:
    return request.app.state.event_bus


def get_workspace_service(request: Request) -> WorkspaceService:
    return request.app.state.workspace_service


def get_page_workspace_service(request: Request) -> PageWorkspaceService:
    return request.app.state.page_workspace_service


def get_proofread_workspace_service(request: Request) -> ProofreadWorkspaceService:
    return request.app.state.proofread_workspace_service


def get_audio_workspace_service(request: Request) -> AudioWorkspaceService:
    return request.app.state.audio_workspace_service


def get_export_workspace_service(request: Request) -> ExportWorkspaceService:
    return request.app.state.export_workspace_service
