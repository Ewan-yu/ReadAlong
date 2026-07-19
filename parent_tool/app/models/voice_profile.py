from __future__ import annotations

from datetime import datetime
from enum import Enum

from pydantic import Field

from app.models.pipeline import FrozenModel


class VoiceProfileSource(str, Enum):
    GENERATED = "generated"
    UPLOADED = "uploaded"


class VoiceProfileStatus(str, Enum):
    PROCESSING = "processing"
    READY = "ready"
    FAILED = "failed"


class VoiceProfile(FrozenModel):
    schema_version: int = 1
    voice_id: str = Field(pattern=r"^v-[a-z0-9-]{3,80}$")
    revision: int = Field(ge=1)
    name: str = Field(min_length=1, max_length=200)
    source_type: VoiceProfileSource
    description: str | None = Field(default=None, max_length=500)
    reference_sha256: str | None = Field(default=None, pattern=r"^[0-9a-f]{64}$")
    reference_duration_seconds: float | None = Field(default=None, gt=0)
    preview_text: str = Field(min_length=1, max_length=500)
    status: VoiceProfileStatus
    progress_message: str | None = Field(default=None, max_length=200)
    failure_message: str | None = Field(default=None, max_length=500)
    warnings: tuple[str, ...] = ()
    is_system: bool = False
    is_default: bool = False
    created_at: datetime
    updated_at: datetime


class VoiceProfileListResponse(FrozenModel):
    voices: tuple[VoiceProfile, ...]


class CreateGeneratedVoiceRequest(FrozenModel):
    name: str = Field(min_length=1, max_length=200)
    description: str = Field(min_length=3, max_length=500)


class UpdateVoiceProfileRequest(FrozenModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    is_default: bool | None = None


class UploadVoiceProfileForm(FrozenModel):
    name: str = Field(min_length=1, max_length=200)
    clip_start_seconds: float = Field(default=0, ge=0, le=3600)
    clip_duration_seconds: float = Field(default=12, ge=3, le=15)
