from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from fastapi.responses import FileResponse

from app.api.dependencies import get_audio_workspace_service
from app.api.routes.pipeline import ERROR_RESPONSES
from app.models.audio_workspace import AudioWorkspaceResponse
from app.services.audio_workspace_service import AudioWorkspaceService


router = APIRouter(prefix="/api/books/{book_id}/audio", tags=["audio"])


@router.get("/workspace", response_model=AudioWorkspaceResponse, responses=ERROR_RESPONSES)
def get_workspace(
    book_id: str,
    service: Annotated[AudioWorkspaceService, Depends(get_audio_workspace_service)],
) -> AudioWorkspaceResponse:
    return service.load(book_id)


@router.get("/revisions/{revision_id}/assets/{asset_path:path}", response_class=FileResponse, responses=ERROR_RESPONSES)
def get_asset(
    book_id: str,
    revision_id: str,
    asset_path: str,
    service: Annotated[AudioWorkspaceService, Depends(get_audio_workspace_service)],
) -> FileResponse:
    return FileResponse(service.asset(book_id, revision_id, asset_path), headers={"Cache-Control": "private, max-age=31536000, immutable"})
