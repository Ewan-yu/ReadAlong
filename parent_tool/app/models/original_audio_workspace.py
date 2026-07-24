from __future__ import annotations

from typing import Literal

from app.models.pipeline import FrozenModel


class OriginalAudioCandidateAssets(FrozenModel):
    vocals_preview: str
    background_preview: str
    waveform_original: str
    waveform_vocals: str
    waveform_background: str


class OriginalAudioWorkspaceResponse(FrozenModel):
    available: bool
    source_filename: str | None = None
    status: Literal[
        "not_available",
        "not_processed",
        "processing",
        "ready_for_review",
        "confirmed",
        "voice_only",
        "failed",
        "stale",
    ]
    candidate_revision_id: str | None = None
    confirmed_revision_id: str | None = None
    model: str | None = None
    duration_ms: int | None = None
    assets: OriginalAudioCandidateAssets | None = None
    lyric_sentence_count: int | None = None
    message: str | None = None
