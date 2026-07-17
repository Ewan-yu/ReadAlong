from __future__ import annotations

import json
from pathlib import Path

import fitz

from app.models.ocr import OcrSentences, SuspectKind, SuspectWord
from app.models.pipeline import PipelineState, StepId
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import CancellationToken, StepRegistry
from app.pipeline.engine import PipelineEngine, SkippedRun
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.pipeline.steps.ocr import OcrStep
from app.pipeline.steps.pages import PageProcessingStep
from app.providers.ocr import ReplayOcrProvider


class FakeSpellChecker:
    def suspects(self, text: str) -> tuple[SuspectWord, ...]:
        if "Helo" in text:
            return (SuspectWord(word="Helo", kind=SuspectKind.PROPER_NOUN),)
        return ()


def _source_pdf(path: Path) -> Path:
    document = fitz.open()
    try:
        page = document.new_page(width=300, height=400)
        page.insert_text((40, 50), "OCR fixture")
        document.save(path)
    finally:
        document.close()
    return path


def _run(engine: PipelineEngine, step_id: StepId, params: dict[str, object], job: str):
    plan = engine.plan("book-1", step_id, params)
    assert not isinstance(plan, SkippedRun)
    prepared = engine.begin(plan, job)
    return engine.execute(prepared, lambda _progress, _message: None, CancellationToken())


def test_ocr_step_replays_response_and_builds_sentence_draft(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "workspace")
    book = paths.book("book-1")
    book.mkdir(parents=True)
    source = _source_pdf(tmp_path / "source.pdf")
    target = book / "source.pdf"
    target.write_bytes(source.read_bytes())
    states = StateRepository(paths)
    states.create(PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256=file_sha256(target)))
    response = json.dumps(
        {
            "result": {
                "layoutParsingResults": [
                    {
                        "prunedResult": {
                            "parsing_res_list": [
                                {
                                    "block_label": "text",
                                    "block_content": 'Helo world. "What now?"',
                                    "block_bbox": [20, 40, 220, 120],
                                },
                                {
                                    "block_label": "text",
                                    "block_content": "♥",
                                    "block_bbox": [30, 150, 50, 180],
                                },
                                {
                                    "block_label": "vision_footnote",
                                    "block_content": "Granny\n奶奶",
                                    "block_bbox": [220, 150, 320, 180],
                                },
                                {"block_label": "number", "block_content": "4", "block_bbox": [1, 1, 10, 10]},
                                {"block_label": "image", "block_bbox": [0, 0, 100, 100]},
                            ]
                        }
                    }
                ]
            }
        },
        ensure_ascii=False,
    )
    replay = ReplayOcrProvider({"p0001.png": response})
    engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry((PageProcessingStep(), OcrStep(replay, FakeSpellChecker()))),
    )

    _run(engine, StepId.PAGES, {}, "12345678-1234-4234-8234-123456789abc")
    success = _run(engine, StepId.OCR, {}, "22345678-1234-4234-8234-123456789abc")

    revision = book / success.output_root
    output = OcrSentences.model_validate_json((revision / "sentences.json").read_text(encoding="utf-8"))
    assert (revision / "responses/p0001.jsonl").read_text(encoding="utf-8") == response
    assert [item.text for item in output.sentences] == ["Helo world.", '"What now?"', "♥", "Granny"]
    assert [item.shared_bbox for item in output.sentences] == [True, True, False, False]
    assert output.sentences[0].suspect_words == (
        SuspectWord(word="Helo", kind=SuspectKind.PROPER_NOUN),
    )
    assert output.sentences[2].status.value == "needs_review"
    assert output.pages[0].blocks_seen == 3
    assert output.pages[0].sentences_created == 4
    assert 0 <= output.sentences[0].bbox.x < 1
    assert output.sentences[0].bbox.x + output.sentences[0].bbox.width <= 1


def test_ocr_step_rejects_invalid_replayed_jsonl(tmp_path: Path) -> None:
    provider = ReplayOcrProvider({"page.png": "not JSON"})
    step = OcrStep(provider, FakeSpellChecker())

    try:
        step._parse_blocks("not JSON", 100, 100)
    except Exception as error:
        assert getattr(error, "code", None) == "OCR_RESPONSE_INVALID"
    else:
        raise AssertionError("invalid JSONL should be rejected")


def test_replay_provider_requires_every_page(tmp_path: Path) -> None:
    provider = ReplayOcrProvider({})
    try:
        provider.recognize(tmp_path / "p0001.png", object(), CancellationToken())  # type: ignore[arg-type]
    except Exception as error:
        assert getattr(error, "code", None) == "OCR_REPLAY_MISSING"
    else:
        raise AssertionError("missing recorded response should be explicit")
