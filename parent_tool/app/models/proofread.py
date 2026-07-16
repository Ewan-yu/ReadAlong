from __future__ import annotations

from app.models.pipeline import FrozenModel


class AutoProofreadParams(FrozenModel):
    """An explicit, temporary M2 gate before the M3 interactive proofread desk exists."""

    accept_ocr_draft: bool = False
