from __future__ import annotations

from pathlib import Path

import fitz
import pytest
from PIL import Image

from app.models.errors import PipelineError
from app.models.pages import PagePlan
from app.models.pipeline import PipelineState, StepId
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import CancellationToken, StepRegistry
from app.pipeline.engine import PipelineEngine, SkippedRun
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.pipeline.steps.pages import PageProcessingStep


def _source_pdf(path: Path, *, wide: bool) -> Path:
    document = fitz.open()
    try:
        width, height = (800, 400) if wide else (400, 600)
        page = document.new_page(width=width, height=height)
        if wide:
            page.draw_rect((0, 0, 380, height), color=None, fill=(0.1, 0.1, 0.1))
            page.draw_rect((420, 0, width, height), color=None, fill=(0.1, 0.1, 0.1))
        else:
            page.insert_text((60, 80), "One reader page")
        document.save(path)
    finally:
        document.close()
    return path


def _engine(tmp_path: Path, source: Path) -> tuple[PipelineEngine, StateRepository, WorkspacePaths]:
    paths = WorkspacePaths(tmp_path / "workspace")
    book = paths.book("book-1")
    book.mkdir(parents=True)
    target = book / "source.pdf"
    target.write_bytes(source.read_bytes())
    states = StateRepository(paths)
    states.create(
        PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256=file_sha256(target))
    )
    return (
        PipelineEngine(states, ArtifactStore(paths), StepRegistry((PageProcessingStep(),))),
        states,
        paths,
    )


def _run(engine: PipelineEngine) -> object:
    plan = engine.plan("book-1", StepId.PAGES, {})
    assert not isinstance(plan, SkippedRun)
    prepared = engine.begin(plan, "12345678-1234-4234-8234-123456789abc")
    return engine.execute(prepared, lambda _progress, _message: None, CancellationToken())


def test_page_step_outputs_split_plan_and_all_image_variants(tmp_path: Path) -> None:
    engine, states, paths = _engine(tmp_path, _source_pdf(tmp_path / "spread.pdf", wide=True))

    success = _run(engine)

    revision = paths.book("book-1") / success.output_root
    page_plan = PagePlan.model_validate_json((revision / "page_plan.json").read_text(encoding="utf-8"))
    assert page_plan.source_pdf_page_count == 1
    entry = page_plan.pages[0]
    assert entry.detect.suspect_split is True
    assert entry.detect.confidence >= 70
    assert entry.decision.mode.value == "split_lr"
    assert entry.decision.confirmed is True
    assert [output.region.value for output in entry.outputs] == ["left", "right"]
    assert [output.page_no for output in entry.outputs] == [1, 2]
    for output in entry.outputs:
        assert (revision / output.ocr_image).is_file()
        assert (revision / output.page_image).is_file()
        assert (revision / output.thumbnail).is_file()
        with Image.open(revision / output.page_image) as page_image:
            assert page_image.format == "WEBP"
            assert page_image.size == (output.width, output.height)
        with Image.open(revision / output.thumbnail) as thumbnail:
            assert thumbnail.format == "JPEG"
            assert max(thumbnail.size) <= page_plan.params.thumbnail_long_edge
    assert states.load("book-1").steps[StepId.PAGES].success == success


def test_page_step_keeps_normal_page(tmp_path: Path) -> None:
    engine, _states, paths = _engine(tmp_path, _source_pdf(tmp_path / "single.pdf", wide=False))

    success = _run(engine)

    revision = paths.book("book-1") / success.output_root
    page_plan = PagePlan.model_validate_json((revision / "page_plan.json").read_text(encoding="utf-8"))
    entry = page_plan.pages[0]
    assert entry.detect.suspect_split is False
    assert entry.decision.mode.value == "keep"
    assert entry.decision.confirmed is True
    assert [output.region.value for output in entry.outputs] == ["full"]


def test_page_step_rejects_changed_source(tmp_path: Path) -> None:
    source = _source_pdf(tmp_path / "single.pdf", wide=False)
    engine, _states, paths = _engine(tmp_path, source)
    plan = engine.plan("book-1", StepId.PAGES, {})
    assert not isinstance(plan, SkippedRun)
    (paths.book("book-1") / "source.pdf").write_bytes(b"changed")
    prepared = engine.begin(plan, "12345678-1234-4234-8234-123456789abc")

    with pytest.raises(PipelineError) as caught:
        engine.execute(prepared, lambda _progress, _message: None, CancellationToken())

    assert caught.value.code == "SOURCE_FILE_CHANGED"
    assert not (paths.book("book-1") / "01_pages" / "revisions").exists()
