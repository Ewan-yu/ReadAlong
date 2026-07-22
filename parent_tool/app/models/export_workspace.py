from __future__ import annotations

from typing import Literal

from pydantic import Field

from app.models.pipeline import FrozenModel


class ExportCheck(FrozenModel):
    id: str
    label: str
    status: Literal["pass", "warning", "error"]
    detail: str


class ExportOriginalAudioInfo(FrozenModel):
    path: str = "original/source.mp3"
    size_bytes: int = Field(gt=0)
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    duration_ms: int | None = Field(default=None, gt=0)


class ExportPackageInfo(FrozenModel):
    filename: str
    page_count: int = Field(ge=0)
    sentence_count: int = Field(ge=0)
    word_timing_sentence_count: int = Field(ge=0)
    audio_provider_counts: dict[str, int] = Field(default_factory=dict)
    original_audio: ExportOriginalAudioInfo | None = None
    size_bytes: int | None = Field(default=None, ge=0)
    sha256: str | None = None


class ExportWorkspaceResponse(FrozenModel):
    ready: bool
    suggested_title: str
    checks: tuple[ExportCheck, ...]
    package: ExportPackageInfo
    export_revision_id: str | None = None
