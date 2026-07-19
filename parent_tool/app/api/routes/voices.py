from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from fastapi.responses import FileResponse

from app.api.dependencies import get_voice_profile_service
from app.api.routes.pipeline import ERROR_RESPONSES
from app.models.voice_profile import VoiceProfileListResponse
from app.services.voice_profile_service import VoiceProfileService


router = APIRouter(prefix="/api/voices", tags=["voices"])


@router.get("", response_model=VoiceProfileListResponse, responses=ERROR_RESPONSES)
def list_voices(
    service: Annotated[VoiceProfileService, Depends(get_voice_profile_service)],
) -> VoiceProfileListResponse:
    return service.list()


@router.get("/{voice_id}/preview", response_class=FileResponse, responses=ERROR_RESPONSES)
def preview_voice(
    voice_id: str,
    service: Annotated[VoiceProfileService, Depends(get_voice_profile_service)],
) -> FileResponse:
    return FileResponse(service.preview(voice_id), headers={"Cache-Control": "private, max-age=31536000, immutable"})
