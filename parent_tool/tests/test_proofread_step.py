from __future__ import annotations

import pytest

from app.models.errors import PipelineError
from app.models.ocr import BoundingBox, OcrPage, OcrParams, OcrSentence, OcrSentences, SentenceStatus
from app.models.pipeline import StepId
from app.models.proofread import AutoProofreadParams
from app.pipeline.definitions import CancellationToken, StepRunContext
from app.pipeline.steps.proofread import AutoProofreadStep


def _sentence(index: int, text: str, status: SentenceStatus = SentenceStatus.SENTENCE) -> OcrSentence:
    return OcrSentence(
        id=f"s{index:04d}", page_no=1, seq=index, text=text,
        bbox=BoundingBox(x=0.1 * index, y=0.1, width=0.2, height=0.1),
        shared_bbox=False, status=status,
    )


def _context(tmp_path):
    source = tmp_path / "02_ocr" / "revisions" / "r-ocr"
    source.mkdir(parents=True)
    document = OcrSentences(
        source_pages_revision="r-pages", params=OcrParams(),
        pages=(OcrPage(page_no=1, ocr_image="ocr/p0001.png", response_path="responses/p0001.jsonl", blocks_seen=2, sentences_created=2),),
        sentences=(_sentence(1, "Hello reader."), _sentence(2, "Good night.")),
    )
    (source / "sentences.json").write_text(document.model_dump_json(), encoding="utf-8")
    staging = tmp_path / "staging"
    staging.mkdir()
    return StepRunContext(
        book_id="book-1", workspace_dir=tmp_path, staging_dir=staging, source_pdf_sha256=None,
        dependency_outputs={StepId.OCR: source}, progress=lambda _value, _message: None,
        cancellation=CancellationToken(),
    )


def test_interactive_proofread_publishes_normalised_confirmed_document(tmp_path):
    context = _context(tmp_path)
    result = AutoProofreadStep().run(context, AutoProofreadParams(
        source_ocr_revision="r-ocr", confirmed_pages=(1,),
        sentences=(_sentence(1, "Hello, reader."), _sentence(2, "Good night.")),
    ))

    final = OcrSentences.model_validate_json((context.staging_dir / "sentences_final.json").read_text(encoding="utf-8"))
    assert result.summary == {"sentence_count": 2}
    assert final.confirmed_pages == (1,)
    assert [sentence.text for sentence in final.sentences] == ["Hello, reader.", "Good night."]
    assert [sentence.id for sentence in final.sentences] == ["s0001", "s0002"]


def test_interactive_proofread_requires_all_pages_and_current_ocr_revision(tmp_path):
    context = _context(tmp_path)
    params = AutoProofreadParams(source_ocr_revision="r-ocr", sentences=(_sentence(1, "Hello reader."),))
    with pytest.raises(PipelineError, match="PROOFREAD_PAGES_NOT_CONFIRMED"):
        AutoProofreadStep().run(context, params)

    with pytest.raises(PipelineError, match="OCR_REVISION_CHANGED"):
        AutoProofreadStep().run(context, params.model_copy(update={"confirmed_pages": (1,), "source_ocr_revision": "r-old"}))
