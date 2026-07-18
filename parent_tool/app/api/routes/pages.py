from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Path, Query, Response
from fastapi.responses import FileResponse

from app.api.dependencies import get_page_workspace_service
from app.api.routes.pipeline import ERROR_RESPONSES
from app.models.page_workspace import PageWorkspaceResponse
from app.services.page_workspace_service import PageWorkspaceService


router = APIRouter(prefix="/api/books/{book_id}/pages", tags=["pages"])


@router.get("/workspace", response_model=PageWorkspaceResponse, responses=ERROR_RESPONSES)
def get_page_workspace(
    book_id: str,
    service: Annotated[PageWorkspaceService, Depends(get_page_workspace_service)],
) -> PageWorkspaceResponse:
    return service.load(book_id)


@router.get("/source/{source_pdf_page}.webp", responses=ERROR_RESPONSES)
def get_source_page_preview(
    book_id: str,
    source_pdf_page: Annotated[int, Path(ge=1)],
    service: Annotated[PageWorkspaceService, Depends(get_page_workspace_service)],
    max_edge: Annotated[int, Query(ge=240, le=2400)] = 1800,
) -> Response:
    content = service.render_source(book_id, source_pdf_page, max_edge)
    return Response(
        content=content,
        media_type="image/webp",
        headers={"Cache-Control": "private, max-age=3600"},
    )


@router.get(
    "/revisions/{revision_id}/assets/{asset_path:path}",
    response_class=FileResponse,
    responses=ERROR_RESPONSES,
)
def get_page_asset(
    book_id: str,
    revision_id: str,
    asset_path: str,
    service: Annotated[PageWorkspaceService, Depends(get_page_workspace_service)],
) -> FileResponse:
    path = service.asset(book_id, revision_id, asset_path)
    return FileResponse(path, headers={"Cache-Control": "private, max-age=31536000, immutable"})
