import pytest
from pydantic import ValidationError

from app.models.pages import (
    PageCrop,
    PageDecision,
    PageDetect,
    PageMode,
    PageOutput,
    PagePlan,
    PagePlanEntry,
    PageProcessParams,
    PageQuality,
    PageRegion,
    SourcePageSize,
)


def _entry(page_no: int, *, region: PageRegion = PageRegion.FULL) -> PagePlanEntry:
    return PagePlanEntry(
        source_pdf_page=1,
        source_size_pt=SourcePageSize(width=574, height=666),
        detect=PageDetect(suspect_split=False, confidence=0),
        decision=PageDecision(mode=PageMode.KEEP, confirmed=True),
        outputs=(
            PageOutput(
                page_no=page_no,
                region=region,
                ocr_image=f"ocr/p{page_no:04d}.png",
                page_image=f"pages/p{page_no:04d}.webp",
                thumbnail=f"thumbnails/p{page_no:04d}.jpg",
                width=100,
                height=200,
            ),
        ),
    )


def test_quality_presets_have_fixed_defaults() -> None:
    clear = PageProcessParams()
    balanced = PageProcessParams(quality=PageQuality.BALANCED)
    compact = PageProcessParams(quality=PageQuality.COMPACT)

    assert (clear.reading_long_edge, clear.webp_quality) == (2000, 82)
    assert (balanced.reading_long_edge, balanced.webp_quality) == (1600, 78)
    assert (compact.reading_long_edge, compact.webp_quality) == (1200, 72)
    assert clear.ocr_dpi == 300
    assert clear.thumbnail_long_edge == 360


@pytest.mark.parametrize(
    "decision",
    [
        {"mode": "keep", "split_ratio": 0.5},
        {"mode": "split_lr", "split_ratio": None},
        {"mode": "split_lr", "split_ratio": 0.05},
        {"mode": "keep", "rotate": 45},
        {"mode": "keep", "crop_pct": {"left": 20, "right": 20, "top": 60, "bottom": 60}},
    ],
)
def test_decision_rejects_invalid_geometry(decision: dict) -> None:
    with pytest.raises(ValidationError):
        PageDecision.model_validate(decision)


def test_split_entry_requires_left_then_right_outputs() -> None:
    with pytest.raises(ValidationError):
        PagePlanEntry(
            source_pdf_page=1,
            source_size_pt=SourcePageSize(width=1000, height=600),
            detect=PageDetect(suspect_split=True, confidence=80, suggested_split_ratio=0.5),
            decision=PageDecision(mode=PageMode.SPLIT_LR, split_ratio=0.5, confirmed=True),
            outputs=(
                PageOutput(
                    page_no=1,
                    region=PageRegion.RIGHT,
                    ocr_image="ocr/p0001.png",
                    page_image="pages/p0001.webp",
                    thumbnail="thumbnails/p0001.jpg",
                    width=100,
                    height=100,
                ),
            ),
        )


def test_plan_requires_continuous_final_page_numbers() -> None:
    with pytest.raises(ValidationError):
        PagePlan(
            source_pdf_sha256="a" * 64,
            source_pdf_page_count=2,
            params=PageProcessParams(),
            pages=(_entry(1), _entry(3)),
        )


def test_crop_requires_positive_remaining_area() -> None:
    with pytest.raises(ValidationError):
        PageCrop(top=20, bottom=20, left=60, right=60)
