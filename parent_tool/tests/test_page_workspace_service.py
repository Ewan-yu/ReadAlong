from __future__ import annotations

import json
from pathlib import Path

import fitz

from app.models.pipeline import PipelineState, StepId, StepStatus
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import CancellationToken, StepRegistry
from app.pipeline.engine import PipelineEngine, SkippedRun
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.pipeline.steps.ocr import OcrStep
from app.pipeline.steps.pages import PageProcessingStep
from app.providers.ocr import ReplayOcrProvider
from app.services.page_workspace_service import PageWorkspaceService


class NoSuspects:
    def suspects(self, _text: str) -> tuple:
        return ()


def _source_pdf(path: Path) -> Path:
    document = fitz.open()
    try:
        page = document.new_page(width=300, height=400)
        page.insert_text((40, 50), "Hello reader.")
        document.save(path)
    finally:
        document.close()
    return path


def _run(engine: PipelineEngine, step_id: StepId, params: dict, job_id: str):
    plan = engine.plan("book-1", step_id, params)
    assert not isinstance(plan, SkippedRun)
    prepared = engine.begin(plan, job_id)
    return engine.execute(prepared, lambda _progress, _message: None, CancellationToken())


def test_workspace_hides_ocr_boxes_after_page_decision_invalidates_ocr(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "workspace")
    book = paths.book("book-1")
    book.mkdir(parents=True)
    target = book / "source.pdf"
    target.write_bytes(_source_pdf(tmp_path / "source.pdf").read_bytes())
    states = StateRepository(paths)
    states.create(
        PipelineState.new(
            book_id="book-1",
            pdf_path="source.pdf",
            pdf_sha256=file_sha256(target),
        )
    )
    response = json.dumps(
        {
            "result": {
                "layoutParsingResults": [
                    {
                        "prunedResult": {
                            "parsing_res_list": [
                                {
                                    "block_label": "text",
                                    "block_content": "Hello reader.",
                                    "block_bbox": [20, 30, 220, 100],
                                }
                            ]
                        }
                    }
                ]
            }
        }
    )
    artifacts = ArtifactStore(paths)
    engine = PipelineEngine(
        states,
        artifacts,
        StepRegistry(
            (
                PageProcessingStep(),
                OcrStep(ReplayOcrProvider({"p0001.png": response}), NoSuspects()),
            )
        ),
    )
    service = PageWorkspaceService(paths, states, artifacts)

    _run(engine, StepId.PAGES, {}, "12345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.OCR, {}, "22345678-1234-4234-8234-123456789abc")

    current = service.load("book-1")
    assert current.ocr_revision_id is not None
    assert [sentence.text for sentence in current.sentences] == ["Hello reader."]

    _run(
        engine,
        StepId.PAGES,
        {
            "page_decisions": [
                {
                    "source_pdf_page": 1,
                    "decision": {
                        "mode": "keep",
                        "crop_pct": {"top": 3},
                        "confirmed": True,
                    },
                }
            ]
        },
        "32345678-1234-4234-8234-123456789abc",
    )

    invalidated = service.load("book-1")
    assert states.load("book-1").steps[StepId.OCR].status is StepStatus.STALE
    assert invalidated.ocr_revision_id is None
    assert invalidated.sentences == ()
