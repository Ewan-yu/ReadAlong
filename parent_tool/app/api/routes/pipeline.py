from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Response, status

from app.api.dependencies import get_job_manager, get_state_repository
from app.jobs.manager import JobManager
from app.models.errors import ApiErrorResponse
from app.models.pipeline import (
    PipelineState,
    RunSkippedResponse,
    RunStartedResponse,
    RunStepRequest,
    StepId,
)
from app.pipeline.engine import SkippedRun
from app.pipeline.state_repository import StateRepository


router = APIRouter(prefix="/api/books", tags=["pipeline"])
ERROR_RESPONSES = {
    404: {"model": ApiErrorResponse},
    409: {"model": ApiErrorResponse},
    422: {"model": ApiErrorResponse},
    500: {"model": ApiErrorResponse},
}


@router.get("/{book_id}/state", response_model=PipelineState, responses=ERROR_RESPONSES)
def get_state(
    book_id: str,
    states: Annotated[StateRepository, Depends(get_state_repository)],
) -> PipelineState:
    return states.load(book_id)


@router.post(
    "/{book_id}/steps/{step_id}/run",
    response_model=RunStartedResponse | RunSkippedResponse,
    responses=ERROR_RESPONSES,
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
