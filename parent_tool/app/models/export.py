from __future__ import annotations

from app.models.pipeline import FrozenModel


class ExportParams(FrozenModel):
    title: str | None = None
    language: str = "en"
