from __future__ import annotations

from app.models.ocr import OcrSentence
from app.models.pages import PagePlan
from app.models.pipeline import FrozenModel


class PageWorkspaceResponse(FrozenModel):
    revision_id: str
    plan: PagePlan
    ocr_revision_id: str | None = None
    sentences: tuple[OcrSentence, ...] = ()
