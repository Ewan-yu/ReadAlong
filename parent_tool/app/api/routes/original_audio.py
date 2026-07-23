from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends

from app.api.dependencies import get_original_audio_review_service
from app.models.errors import ApiErrorResponse
from app.models.pipeline import StepSuccess
from app.services.original_audio_review_service import OriginalAudioReviewService


router = APIRouter(prefix="/api/books/{book_id}/original-audio", tags=["original-audio"])
ERROR_RESPONSES = {404: {"model": ApiErrorResponse}, 409: {"model": ApiErrorResponse}, 422: {"model": ApiErrorResponse}, 500: {"model": ApiErrorResponse}}


@router.post("/candidates/current/confirm", response_model=StepSuccess, responses=ERROR_RESPONSES)
def confirm_current_candidate(
    book_id: str,
    service: Annotated[OriginalAudioReviewService, Depends(get_original_audio_review_service)],
) -> StepSuccess:
    return service.confirm_current(book_id)
