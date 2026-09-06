from __future__ import annotations

from typing import Literal

from app.models.pipeline import FrozenModel


class TimelineWorkspaceSentence(FrozenModel):
    """One proofread sentence joined with its lyric timeline state.

    The proofread OCR text is the authoritative reading script: the audio can
    legitimately skip cover credits or word lists, so an unmatched sentence is
    presented for human review instead of being treated as an error.
    """

    sentence_id: str
    page_no: int
    seq: int
    text: str
    status: Literal["matched", "suspect_missing", "confirmed_excluded"]
    # How the sentence entered the timeline; None when it is not in it.
    source: Literal["asr", "manual_adjusted", "manual_added"] | None = None
    start_ms: int | None = None
    end_ms: int | None = None
    reason: str | None = None
    detail: str | None = None
    previous_matched_id: str | None = None
    next_matched_id: str | None = None
    nearby_asr: tuple[str, ...] = ()


class TimelineWorkspaceResponse(FrozenModel):
    available: bool
    status: Literal[
        "not_available",
        "not_generated",
        "processing",
        "failed",
        "stale",
        "ready",
    ]
    message: str | None = None
    timeline_revision_id: str | None = None
    alignment_strategy: str | None = None
    whisper_model: str | None = None
    duration_ms: int | None = None
    matched_count: int = 0
    suspect_missing_count: int = 0
    confirmed_excluded_count: int = 0
    sentences: tuple[TimelineWorkspaceSentence, ...] = ()


class TimelineReviewUpdateRequest(FrozenModel):
    """Replace the parent-confirmed set of sentences the narration skips."""

    confirmed_not_narrated: tuple[str, ...]


class TimelineReviewUpdateResponse(FrozenModel):
    confirmed_not_narrated: tuple[str, ...]
