from __future__ import annotations

from enum import Enum

from pydantic import Field, model_validator

from app.models.pipeline import FrozenModel


class OcrModel(str, Enum):
    PADDLE_OCR_VL = "PaddleOCR-VL-1.6"


class OcrParams(FrozenModel):
    """Stable, non-secret controls for the OCR pipeline step."""

    model: OcrModel = OcrModel.PADDLE_OCR_VL
    request_interval_seconds: float = Field(default=0.5, ge=0.5, le=10)
    max_attempts: int = Field(default=4, ge=1, le=8)
    poll_interval_seconds: float = Field(default=2, ge=0.5, le=15)
    poll_timeout_seconds: int = Field(default=300, ge=10, le=1800)


class SentenceStatus(str, Enum):
    SENTENCE = "sentence"
    NEEDS_REVIEW = "needs_review"


class SuspectKind(str, Enum):
    SPELLING = "spelling"
    PROPER_NOUN = "proper_noun"


class BoundingBox(FrozenModel):
    x: float = Field(ge=0, le=1)
    y: float = Field(ge=0, le=1)
    width: float = Field(gt=0, le=1)
    height: float = Field(gt=0, le=1)

    @model_validator(mode="after")
    def stays_within_page(self) -> "BoundingBox":
        if self.x + self.width > 1 + 1e-6 or self.y + self.height > 1 + 1e-6:
            raise ValueError("bounding box must stay within the page")
        return self


class SuspectWord(FrozenModel):
    word: str = Field(min_length=1)
    kind: SuspectKind


class OcrSentence(FrozenModel):
    id: str = Field(pattern=r"^s[0-9]{4,}$")
    page_no: int = Field(ge=1)
    seq: int = Field(ge=1)
    text: str = Field(min_length=1)
    bbox: BoundingBox
    shared_bbox: bool
    status: SentenceStatus
    suspect_words: tuple[SuspectWord, ...] = ()


class OcrPage(FrozenModel):
    page_no: int = Field(ge=1)
    ocr_image: str
    response_path: str
    blocks_seen: int = Field(ge=0)
    sentences_created: int = Field(ge=0)


class OcrSentences(FrozenModel):
    schema_version: int = 1
    source_pages_revision: str = Field(min_length=1)
    params: OcrParams
    pages: tuple[OcrPage, ...]
    sentences: tuple[OcrSentence, ...]
    # OCR 初稿不包含人工确认；校对步骤发布的最终句子表会记录已确认的阅读页。
    confirmed_pages: tuple[int, ...] = ()

    @model_validator(mode="after")
    def validates_sequences(self) -> "OcrSentences":
        page_numbers = [page.page_no for page in self.pages]
        if page_numbers != list(range(1, len(page_numbers) + 1)):
            raise ValueError("OCR pages must be continuous and ordered")
        if [item.seq for item in self.sentences] != list(range(1, len(self.sentences) + 1)):
            raise ValueError("sentence sequence must be continuous and ordered")
        if [item.id for item in self.sentences] != [
            f"s{index:04d}" for index in range(1, len(self.sentences) + 1)
        ]:
            raise ValueError("sentence identifiers must be continuous and ordered")
        if tuple(sorted(set(self.confirmed_pages))) != self.confirmed_pages:
            raise ValueError("confirmed pages must be unique and ordered")
        if any(page_no not in page_numbers for page_no in self.confirmed_pages):
            raise ValueError("confirmed page must exist in OCR pages")
        return self
