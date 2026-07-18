from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from fastapi.responses import FileResponse

from app.api.dependencies import get_export_workspace_service
from app.api.routes.pipeline import ERROR_RESPONSES
from app.models.export_workspace import ExportWorkspaceResponse
from app.services.export_workspace_service import ExportWorkspaceService


router = APIRouter(prefix="/api/books/{book_id}/export", tags=["export"])


@router.get("/workspace", response_model=ExportWorkspaceResponse, responses=ERROR_RESPONSES)
def get_workspace(book_id: str, service: Annotated[ExportWorkspaceService, Depends(get_export_workspace_service)]) -> ExportWorkspaceResponse:
    return service.load(book_id)


@router.get("/revisions/{revision_id}/download", response_class=FileResponse, responses=ERROR_RESPONSES)
def download(book_id: str, revision_id: str, service: Annotated[ExportWorkspaceService, Depends(get_export_workspace_service)]) -> FileResponse:
    path = service.bundle(book_id, revision_id)
    return FileResponse(path, filename=path.name, media_type="application/octet-stream")
