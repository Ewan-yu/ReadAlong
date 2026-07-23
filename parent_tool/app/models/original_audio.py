from __future__ import annotations

from typing import Literal

from app.models.pipeline import FrozenModel


class OriginalAudioParams(FrozenModel):
    """Stable, intentionally small surface for the first separation provider."""

    model: Literal["htdemucs"] = "htdemucs"

