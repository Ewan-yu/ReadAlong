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
    reference_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    reference_duration_seconds: float = Field(gt=0)
    preview_text: str = Field(min_length=1, max_length=500)
    status: VoiceProfileStatus
    warnings: tuple[str, ...] = ()
    is_system: bool = False
    is_default: bool = False
    created_at: datetime
    updated_at: datetime


class VoiceProfileListResponse(FrozenModel):
    voices: tuple[VoiceProfile, ...]
