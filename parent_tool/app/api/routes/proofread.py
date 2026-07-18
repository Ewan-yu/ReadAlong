from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Response, status

from app.api.dependencies import get_job_manager, get_proofread_workspace_service
from app.jobs.manager import JobManager
from app.models.errors import ApiErrorResponse
from app.models.pipeline import RunSkippedResponse, RunStartedResponse, StepId
from app.models.proofread import (
    AutoProofreadParams,
    ProofreadTextCheckRequest,
    ProofreadTextCheckResponse,
)
from app.models.proofread_workspace import ProofreadWorkspaceResponse
from app.pipeline.steps.ocr import EnglishSpellChecker
from app.pipeline.engine import SkippedRun
from app.services.proofread_workspace_service import ProofreadWorkspaceService


router = APIRouter(prefix="/api/books/{book_id}/proofread", tags=["proofread"])
ERROR_RESPONSES = {404: {"model": ApiErrorResponse}, 409: {"model": ApiErrorResponse}, 422: {"model": ApiErrorResponse}, 500: {"model": ApiErrorResponse}}


@router.get("/workspace", response_model=ProofreadWorkspaceResponse, responses=ERROR_RESPONSES)
def get_workspace(
    book_id: str,
    service: Annotated[ProofreadWorkspaceService, Depends(get_proofread_workspace_service)],
) -> ProofreadWorkspaceResponse:
    return service.load(book_id)


@router.post("/publish", response_model=RunStartedResponse | RunSkippedResponse, responses={200: {"model": RunSkippedResponse}, **ERROR_RESPONSES})
def publish(
    book_id: str,
    params: AutoProofreadParams,
    response: Response,
    manager: Annotated[JobManager, Depends(get_job_manager)],
) -> RunStartedResponse | RunSkippedResponse:
    result = manager.start(book_id, StepId.PROOFREAD, params.model_dump(mode="json"))
    if isinstance(result, SkippedRun):
        response.status_code = status.HTTP_200_OK
        return RunSkippedResponse(state=result.state)
    response.status_code = status.HTTP_202_ACCEPTED
    return RunStartedResponse(job_id=result.job_id)


@router.post("/check-text", response_model=ProofreadTextCheckResponse, responses=ERROR_RESPONSES)
def check_text(request: ProofreadTextCheckRequest) -> ProofreadTextCheckResponse:
    return ProofreadTextCheckResponse(suspect_words=EnglishSpellChecker().suspects(request.text))
