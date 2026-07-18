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
MAX_ORIGINAL_AUDIO_BYTES = 500 * 1024 * 1024


async def _save_upload(
    upload: UploadFile,
    *,
    destination: Path,
    max_bytes: int,
    too_large_code: str,
    too_large_message: str,
) -> None:
    total = 0
    with destination.open("wb") as temporary:
        while chunk := await upload.read(1024 * 1024):
            total += len(chunk)
            if total > max_bytes:
                raise PipelineError(
                    too_large_code,
                    too_large_message,
                    details={"max_bytes": max_bytes},
                    status_code=422,
                )
            temporary.write(chunk)


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=PipelineState,
    responses=ERROR_RESPONSES,
)
async def create_book(
    pdf: Annotated[UploadFile, File(description="要处理的 PDF 文件")],
    workspace: Annotated[WorkspaceService, Depends(get_workspace_service)],
    original_audio: Annotated[
        UploadFile | None,
        File(description="可选的绘本原音 MP3"),
    ] = None,
) -> PipelineState:
    filename = pdf.filename or "book.pdf"
    if not filename.lower().endswith(".pdf"):
        raise PipelineError("SOURCE_FILE_INVALID", "请选择可读取的 PDF 文件。", status_code=422)
    if original_audio is not None and not (original_audio.filename or "").lower().endswith(
        ".mp3"
    ):
        raise PipelineError(
            "ORIGINAL_AUDIO_INVALID",
            "请选择可读取的 MP3 原音文件。",
            status_code=422,
        )
    workspace.paths.root.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    audio_temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", suffix=".pdf", prefix=".upload-", dir=workspace.paths.root, delete=False
        ) as temporary:
            temporary_path = Path(temporary.name)
            pass
        await _save_upload(
            pdf,
            destination=temporary_path,
            max_bytes=MAX_SOURCE_PDF_BYTES,
            too_large_code="SOURCE_FILE_TOO_LARGE",
            too_large_message="PDF 文件不能超过 500MB。",
        )
        if original_audio is not None:
            with tempfile.NamedTemporaryFile(
                mode="wb",
                suffix=".mp3",
                prefix=".audio-upload-",
                dir=workspace.paths.root,
                delete=False,
            ) as temporary:
                audio_temporary_path = Path(temporary.name)
            await _save_upload(
                original_audio,
                destination=audio_temporary_path,
                max_bytes=MAX_ORIGINAL_AUDIO_BYTES,
                too_large_code="ORIGINAL_AUDIO_TOO_LARGE",
                too_large_message="原音 MP3 不能超过 500MB。",
            )
        return workspace.create_from_pdf(
            temporary_path,
            workspace.next_book_id(filename),
            original_audio=audio_temporary_path,
        )
    finally:
        await pdf.close()
        if original_audio is not None:
            await original_audio.close()
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        if audio_temporary_path is not None:
            audio_temporary_path.unlink(missing_ok=True)


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
