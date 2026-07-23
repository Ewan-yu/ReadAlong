from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Response, status
from fastapi.responses import FileResponse

from app.api.dependencies import get_job_manager, get_original_audio_review_service
from app.jobs.manager import JobManager
from app.models.errors import ApiErrorResponse
from app.models.original_audio import OriginalAudioParams
from app.models.original_timeline import OriginalTimelineParams
from app.models.original_audio_workspace import OriginalAudioWorkspaceResponse
from app.models.pipeline import RunSkippedResponse, RunStartedResponse, StepId, StepSuccess
from app.pipeline.engine import SkippedRun
from app.services.original_audio_review_service import OriginalAudioReviewService


router = APIRouter(prefix="/api/books/{book_id}/original-audio", tags=["original-audio"])
ERROR_RESPONSES = {404: {"model": ApiErrorResponse}, 409: {"model": ApiErrorResponse}, 422: {"model": ApiErrorResponse}, 500: {"model": ApiErrorResponse}}


@router.get("/workspace", response_model=OriginalAudioWorkspaceResponse, responses=ERROR_RESPONSES)
def get_workspace(
    book_id: str,
    service: Annotated[OriginalAudioReviewService, Depends(get_original_audio_review_service)],
) -> OriginalAudioWorkspaceResponse:
    return service.workspace(book_id)


@router.post("/separate", response_model=RunStartedResponse | RunSkippedResponse, responses={200: {"model": RunSkippedResponse}, **ERROR_RESPONSES})
def separate(
    book_id: str,
    response: Response,
    manager: Annotated[JobManager, Depends(get_job_manager)],
    params: OriginalAudioParams = OriginalAudioParams(),
) -> RunStartedResponse | RunSkippedResponse:
    result = manager.start(book_id, StepId.ORIGINAL_AUDIO, params.model_dump(mode="json"), force=True)
    if isinstance(result, SkippedRun):
        response.status_code = status.HTTP_200_OK
        return RunSkippedResponse(state=result.state)
    response.status_code = status.HTTP_202_ACCEPTED
    return RunStartedResponse(job_id=result.job_id)


@router.post("/timeline", response_model=RunStartedResponse | RunSkippedResponse, responses={200: {"model": RunSkippedResponse}, **ERROR_RESPONSES})
def build_timeline(
    book_id: str,
    response: Response,
    manager: Annotated[JobManager, Depends(get_job_manager)],
    params: OriginalTimelineParams = OriginalTimelineParams(),
) -> RunStartedResponse | RunSkippedResponse:
    """Create child-facing word timings from the confirmed vocal stem only."""

    result = manager.start(book_id, StepId.ORIGINAL_TIMELINE, params.model_dump(mode="json"))
    if isinstance(result, SkippedRun):
        response.status_code = status.HTTP_200_OK
        return RunSkippedResponse(state=result.state)
    response.status_code = status.HTTP_202_ACCEPTED
    return RunStartedResponse(job_id=result.job_id)


@router.get("/source", response_class=FileResponse, responses=ERROR_RESPONSES)
def source_asset(
    book_id: str,
    service: Annotated[OriginalAudioReviewService, Depends(get_original_audio_review_service)],
) -> FileResponse:
    return FileResponse(service.source_asset(book_id), headers={"Cache-Control": "private, no-store"})


@router.post("/background/disable", status_code=status.HTTP_204_NO_CONTENT, responses=ERROR_RESPONSES)
def disable_background(
    book_id: str,
    service: Annotated[OriginalAudioReviewService, Depends(get_original_audio_review_service)],
) -> Response:
    service.disable_background(book_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/candidates/{candidate_id}/assets/{asset_path:path}", response_class=FileResponse, responses=ERROR_RESPONSES)
def candidate_asset(
    book_id: str,
    candidate_id: str,
    asset_path: str,
    service: Annotated[OriginalAudioReviewService, Depends(get_original_audio_review_service)],
) -> FileResponse:
    return FileResponse(service.candidate_asset(book_id, candidate_id, asset_path), headers={"Cache-Control": "private, no-store"})


@router.post("/candidates/current/confirm", response_model=StepSuccess, responses=ERROR_RESPONSES)
def confirm_current_candidate(
    book_id: str,
    service: Annotated[OriginalAudioReviewService, Depends(get_original_audio_review_service)],
) -> StepSuccess:
    return service.confirm_current(book_id)
