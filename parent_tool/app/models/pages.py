from __future__ import annotations

from enum import Enum
from pathlib import PurePosixPath
from typing import Literal

from pydantic import Field, model_validator

from app.models.pipeline import FrozenModel


class PageQuality(str, Enum):
    CLEAR = "clear"
    BALANCED = "balanced"
    COMPACT = "compact"


class PageMode(str, Enum):
    KEEP = "keep"
    SPLIT_LR = "split_lr"


class PageRegion(str, Enum):
    FULL = "full"
    LEFT = "left"
    RIGHT = "right"


_QUALITY_DEFAULTS = {
    PageQuality.CLEAR: (2000, 82),
    PageQuality.BALANCED: (1600, 78),
    PageQuality.COMPACT: (1200, 72),
}


class PageProcessParams(FrozenModel):
    quality: PageQuality = PageQuality.CLEAR
    reading_long_edge: int = Field(default=2000, ge=800, le=4000)
    webp_quality: int = Field(default=82, ge=1, le=100)
    ocr_dpi: int = Field(default=300, ge=150, le=600)
    detection_dpi: int = Field(default=96, ge=48, le=200)
    thumbnail_long_edge: int = Field(default=360, ge=120, le=800)
    thumbnail_quality: int = Field(default=78, ge=1, le=100)
    split_detection_enabled: bool = True
    wide_ratio_threshold: float = Field(default=1.3, gt=1, le=3)
    center_window_start: float = Field(default=0.4, ge=0, lt=0.5)
    center_window_end: float = Field(default=0.6, gt=0.5, le=1)
    confirmation_confidence: int = Field(default=70, ge=0, le=100)

    @model_validator(mode="before")
    @classmethod
    def apply_quality_defaults(cls, value: object) -> object:
        if isinstance(value, cls):
            return value
        data = dict(value or {})
        quality = PageQuality(data.get("quality", PageQuality.CLEAR))
        long_edge, quality_value = _QUALITY_DEFAULTS[quality]
        data.setdefault("reading_long_edge", long_edge)
        data.setdefault("webp_quality", quality_value)
        return data


class PageCrop(FrozenModel):
    top: float = Field(default=0, ge=0, le=20)
    right: float = Field(default=0, ge=0, le=20)
    bottom: float = Field(default=0, ge=0, le=20)
    left: float = Field(default=0, ge=0, le=20)

    @model_validator(mode="after")
    def validate_remaining_area(self) -> "PageCrop":
        if self.left + self.right >= 100 or self.top + self.bottom >= 100:
            raise ValueError("crop must leave positive area")
        return self


class PageDecision(FrozenModel):
    mode: PageMode
    split_ratio: float | None = Field(default=None, ge=0.1, le=0.9)
    rotate: Literal[0, 90, 180, 270] = 0
    crop_pct: PageCrop = Field(default_factory=PageCrop)
    confirmed: bool = False

    @model_validator(mode="after")
    def validate_mode(self) -> "PageDecision":
        if self.mode is PageMode.KEEP and self.split_ratio is not None:
            raise ValueError("keep decision cannot contain split_ratio")
        if self.mode is PageMode.SPLIT_LR and self.split_ratio is None:
            raise ValueError("split decision requires split_ratio")
        return self


class PageDetect(FrozenModel):
    suspect_split: bool
    confidence: int = Field(ge=0, le=100)
    suggested_split_ratio: float | None = Field(default=None, ge=0.1, le=0.9)

    @model_validator(mode="after")
    def validate_suggestion(self) -> "PageDetect":
        if self.suspect_split != (self.suggested_split_ratio is not None):
            raise ValueError("split suggestion must match suspect_split")
        return self


class SourcePageSize(FrozenModel):
    width: float = Field(gt=0)
    height: float = Field(gt=0)


def _validate_output_path(value: str) -> str:
    if not value or not value.isascii() or "\\" in value:
        raise ValueError("output path must be an ASCII POSIX relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError("output path must stay inside the revision")
    return path.as_posix()


class PageOutput(FrozenModel):
    page_no: int = Field(ge=1)
    region: PageRegion
    ocr_image: str
    page_image: str
    thumbnail: str
    width: int = Field(gt=0)
    height: int = Field(gt=0)

    @model_validator(mode="after")
    def validate_paths(self) -> "PageOutput":
        for value in (self.ocr_image, self.page_image, self.thumbnail):
            _validate_output_path(value)
        return self


class PagePlanEntry(FrozenModel):
    source_pdf_page: int = Field(ge=1)
    source_size_pt: SourcePageSize
    detect: PageDetect
    decision: PageDecision
    outputs: tuple[PageOutput, ...] = Field(min_length=1, max_length=2)

    @model_validator(mode="after")
    def validate_outputs(self) -> "PagePlanEntry":
        if self.decision.mode is PageMode.KEEP:
            if len(self.outputs) != 1 or self.outputs[0].region is not PageRegion.FULL:
                raise ValueError("keep decision must produce one full output")
        else:
            if len(self.outputs) != 2 or tuple(item.region for item in self.outputs) != (
                PageRegion.LEFT,
                PageRegion.RIGHT,
            ):
                raise ValueError("split decision must produce left then right outputs")
        return self


class PagePlan(FrozenModel):
    schema_version: Literal[1] = 1
    source_pdf_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    source_pdf_page_count: int = Field(ge=1)
    params: PageProcessParams
    pages: tuple[PagePlanEntry, ...] = Field(min_length=1)

    @model_validator(mode="after")
    def validate_page_sequence(self) -> "PagePlan":
        if len(self.pages) != self.source_pdf_page_count:
            raise ValueError("page plan must cover every source PDF page")
        source_pages = [entry.source_pdf_page for entry in self.pages]
        if source_pages != list(range(1, self.source_pdf_page_count + 1)):
            raise ValueError("source PDF pages must be continuous and ordered")
        final_pages = [item.page_no for entry in self.pages for item in entry.outputs]
        if final_pages != list(range(1, len(final_pages) + 1)):
            raise ValueError("final page numbers must be continuous and ordered")
        return self
