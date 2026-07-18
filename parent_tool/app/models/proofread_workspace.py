from __future__ import annotations

from app.models.ocr import OcrSentence
from app.models.pipeline import FrozenModel


class ProofreadPage(FrozenModel):
    page_no: int
    image: str
    thumbnail: str


class ProofreadWorkspaceResponse(FrozenModel):
    pages_revision_id: str
    ocr_revision_id: str
    proofread_revision_id: str | None = None
    pages: tuple[ProofreadPage, ...]
    sentences: tuple[OcrSentence, ...]
    confirmed_pages: tuple[int, ...] = ()
