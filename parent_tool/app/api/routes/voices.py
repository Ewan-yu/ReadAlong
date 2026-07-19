from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, Response, UploadFile, status
from fastapi.responses import FileResponse

from app.api.dependencies import get_voice_profile_service
from app.api.routes.pipeline import ERROR_RESPONSES, _save_upload
from app.models.errors import PipelineError
from app.models.voice_profile import (
    CreateGeneratedVoiceRequest,
    UpdateVoiceProfileRequest,
    VoiceProfile,
    VoiceProfileListResponse,
)
from app.services.voice_profile_service import VoiceProfileService


router = APIRouter(prefix="/api/voices", tags=["voices"])
MAX_VOICE_UPLOAD_BYTES = 100 * 1024 * 1024


@router.get("", response_model=VoiceProfileListResponse, responses=ERROR_RESPONSES)
def list_voices(
    service: Annotated[VoiceProfileService, Depends(get_voice_profile_service)],
) -> VoiceProfileListResponse:
    return service.list()


@router.post(
    "/generated",
    status_code=status.HTTP_202_ACCEPTED,
    response_model=VoiceProfile,
    responses=ERROR_RESPONSES,
)
def create_generated_voice(
    request: CreateGeneratedVoiceRequest,
    background_tasks: BackgroundTasks,
    service: Annotated[VoiceProfileService, Depends(get_voice_profile_service)],
) -> VoiceProfile:
    profile = service.begin_generated(request.name, request.description)
    background_tasks.add_task(service.generate, profile.voice_id)
    return profile


@router.post(
    "/upload",
    status_code=status.HTTP_202_ACCEPTED,
    response_model=VoiceProfile,
    responses=ERROR_RESPONSES,
)
async def create_uploaded_voice(
    background_tasks: BackgroundTasks,
    service: Annotated[VoiceProfileService, Depends(get_voice_profile_service)],
    audio: Annotated[UploadFile, File(description="3–15 秒、清晰的 WAV 或 MP3 人声")],
    name: Annotated[str, Form(min_length=1, max_length=200)],
    clip_start_seconds: Annotated[float, Form(ge=0, le=3600)] = 0,
    clip_duration_seconds: Annotated[float, Form(ge=3, le=15)] = 12,
) -> VoiceProfile:
    filename = audio.filename or ""
    if Path(filename).suffix.lower() not in {".wav", ".mp3"}:
        raise PipelineError("VOICE_UPLOAD_INVALID", "请上传 WAV 或 MP3 格式的声音样本。", status_code=422)
    service.root.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", suffix=Path(filename).suffix, prefix=".voice-upload-", dir=service.root, delete=False
        ) as temporary:
            temporary_path = Path(temporary.name)
        await _save_upload(
            audio,
            destination=temporary_path,
            max_bytes=MAX_VOICE_UPLOAD_BYTES,
            too_large_code="VOICE_UPLOAD_TOO_LARGE",
            too_large_message="声音样本不能超过 100MB。",
        )
        profile = service.begin_uploaded(name, temporary_path)
        temporary_path = None
        background_tasks.add_task(
            service.prepare_upload,
            profile.voice_id,
            start_seconds=clip_start_seconds,
            duration_seconds=clip_duration_seconds,
        )
        return profile
    finally:
        await audio.close()
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


@router.get("/{voice_id}", response_model=VoiceProfile, responses=ERROR_RESPONSES)
def get_voice(
    voice_id: str,
    service: Annotated[VoiceProfileService, Depends(get_voice_profile_service)],
) -> VoiceProfile:
    return service.get(voice_id)


@router.get("/{voice_id}/preview", response_class=FileResponse, responses=ERROR_RESPONSES)
def preview_voice(
    voice_id: str,
    service: Annotated[VoiceProfileService, Depends(get_voice_profile_service)],
) -> FileResponse:
    return FileResponse(
        service.preview(voice_id), headers={"Cache-Control": "private, max-age=31536000, immutable"}
    )


@router.patch("/{voice_id}", response_model=VoiceProfile, responses=ERROR_RESPONSES)
def update_voice(
    voice_id: str,
    request: UpdateVoiceProfileRequest,
    service: Annotated[VoiceProfileService, Depends(get_voice_profile_service)],
) -> VoiceProfile:
    return service.update(voice_id, name=request.name, is_default=request.is_default)


@router.delete("/{voice_id}", status_code=status.HTTP_204_NO_CONTENT, responses=ERROR_RESPONSES)
def delete_voice(
    voice_id: str,
    service: Annotated[VoiceProfileService, Depends(get_voice_profile_service)],
) -> Response:
    service.delete(voice_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{voice_id}/regenerate-preview", status_code=status.HTTP_202_ACCEPTED, responses=ERROR_RESPONSES)
def regenerate_preview(
    voice_id: str,
    background_tasks: BackgroundTasks,
    service: Annotated[VoiceProfileService, Depends(get_voice_profile_service)],
) -> Response:
    service.get(voice_id)
    background_tasks.add_task(service.regenerate_preview, voice_id)
    return Response(status_code=status.HTTP_202_ACCEPTED)
