from __future__ import annotations

from pydantic import Field, model_validator

from app.models.ocr import OcrSentence, SuspectWord
from app.models.pipeline import FrozenModel


class AutoProofreadParams(FrozenModel):
    """Immutable commit payload for the human OCR proofread workspace.

    ``accept_ocr_draft`` remains as a compatibility path for existing M2 automation;
    interactive clients submit the complete edited sentence table instead.
    """

    accept_ocr_draft: bool = False
    source_ocr_revision: str | None = None
    sentences: tuple[OcrSentence, ...] = Field(default_factory=tuple)
    confirmed_pages: tuple[int, ...] = Field(default_factory=tuple)

    @model_validator(mode="after")
    def validates_interactive_commit(self) -> "AutoProofreadParams":
        if not self.sentences:
            return self
        if not self.source_ocr_revision:
            raise ValueError("interactive proofread commit requires source_ocr_revision")
        if [item.seq for item in self.sentences] != list(range(1, len(self.sentences) + 1)):
            raise ValueError("sentence sequence must be continuous and ordered")
        if [item.id for item in self.sentences] != [
            f"s{index:04d}" for index in range(1, len(self.sentences) + 1)
        ]:
            raise ValueError("sentence identifiers must be continuous and ordered")
        if tuple(sorted(set(self.confirmed_pages))) != self.confirmed_pages:
            raise ValueError("confirmed pages must be unique and ordered")
        return self


class ProofreadTextCheckRequest(FrozenModel):
    text: str = Field(min_length=1, max_length=2000)


class ProofreadTextCheckResponse(FrozenModel):
    suspect_words: tuple[SuspectWord, ...] = ()
