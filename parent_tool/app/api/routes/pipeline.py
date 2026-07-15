from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, File, Response, UploadFile, status

from app.api.dependencies import (
    get_job_manager,
    get_state_repository,
    get_workspace_service,
)
from app.jobs.manager import JobManager
from app.models.errors import ApiErrorResponse, PipelineError
from app.models.pipeline import (
    PipelineState,
    RunSkippedResponse,
    RunStartedResponse,
    RunStepRequest,
    StepId,
)
from app.pipeline.engine import SkippedRun
from app.pipeline.state_repository import StateRepository
from app.services.workspace_service import WorkspaceService


router = APIRouter(prefix="/api/books", tags=["pipeline"])
ERROR_RESPONSES = {
    404: {"model": ApiErrorResponse},
    409: {"model": ApiErrorResponse},
    422: {"model": ApiErrorResponse},
    500: {"model": ApiErrorResponse},
}
MAX_SOURCE_PDF_BYTES = 500 * 1024 * 1024


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=PipelineState,
    responses=ERROR_RESPONSES,
)
async def create_book(
    pdf: Annotated[UploadFile, File(description="要处理的 PDF 文件")],
    workspace: Annotated[WorkspaceService, Depends(get_workspace_service)],
) -> PipelineState:
    filename = pdf.filename or "book.pdf"
    if not filename.lower().endswith(".pdf"):
        raise PipelineError("SOURCE_FILE_INVALID", "请选择可读取的 PDF 文件。", status_code=422)
    workspace.paths.root.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", suffix=".pdf", prefix=".upload-", dir=workspace.paths.root, delete=False
        ) as temporary:
            temporary_path = Path(temporary.name)
            total = 0
            while chunk := await pdf.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_SOURCE_PDF_BYTES:
                    raise PipelineError(
                        "SOURCE_FILE_TOO_LARGE",
                        "PDF 文件不能超过 500MB。",
                        details={"max_bytes": MAX_SOURCE_PDF_BYTES},
                        status_code=422,
                    )
                temporary.write(chunk)
        return workspace.create_from_pdf(temporary_path, workspace.next_book_id(filename))
    finally:
        await pdf.close()
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


@router.get("/{book_id}/state", response_model=PipelineState, responses=ERROR_RESPONSES)
def get_state(
    book_id: str,
    states: Annotated[StateRepository, Depends(get_state_repository)],
) -> PipelineState:
    return states.load(book_id)


@router.post(
    "/{book_id}/steps/{step_id}/run",
    status_code=status.HTTP_202_ACCEPTED,
    response_model=RunStartedResponse | RunSkippedResponse,
    responses={200: {"model": RunSkippedResponse}, **ERROR_RESPONSES},
)
def run_step(
    book_id: str,
    step_id: StepId,
    request: RunStepRequest,
    response: Response,
    manager: Annotated[JobManager, Depends(get_job_manager)],
) -> RunStartedResponse | RunSkippedResponse:
    result = manager.start(book_id, step_id, request.params, force=request.force)
    if isinstance(result, SkippedRun):
        response.status_code = status.HTTP_200_OK
        return RunSkippedResponse(state=result.state)
    response.status_code = status.HTTP_202_ACCEPTED
    return RunStartedResponse(job_id=result.job_id)
