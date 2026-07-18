from __future__ import annotations

from pathlib import Path

import fitz
import pytest
from pydantic import BaseModel, ConfigDict

from app.models.audio import AudioWordTiming, SynthesizedAudio
from app.models.errors import PipelineError
from app.models.ocr import BoundingBox, OcrSentence, OcrSentences, SentenceStatus
from app.models.pipeline import PipelineState, StepId, StepResult
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import CancellationToken, StepRegistry
from app.pipeline.engine import PipelineEngine, SkippedRun
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.pipeline.steps import AudioStep, AutoProofreadStep, ExportStep, PageProcessingStep
from app.services.audio_workspace_service import AudioWorkspaceService
from app.services.export_workspace_service import ExportWorkspaceService


class FakeParams(BaseModel):
    model_config = ConfigDict(extra="forbid")


class FakeOcrStep:
    step_id = StepId.OCR
    implementation_version = "fake-ocr-v1"
    params_model = FakeParams

    def run(self, context, _params):
        document = OcrSentences(
            source_pages_revision="r-pages",
            params={},
            pages=(),
            sentences=(
                OcrSentence(
                    id="s0001",
                    page_no=1,
                    seq=1,
                    text="Hello world.",
                    bbox=BoundingBox(x=0.1, y=0.1, width=0.3, height=0.1),
                    shared_bbox=False,
                    status=SentenceStatus.SENTENCE,
                ),
            ),
        )
        (context.staging_dir / "sentences.json").write_text(
            document.model_dump_json(), encoding="utf-8"
        )
        return StepResult(outputs=("sentences.json",))


class FakeTts:
    def synthesize(self, _text, _voice, output_wav, _cancellation):
        output_wav.parent.mkdir(parents=True, exist_ok=True)
        output_wav.write_bytes(b"fake wav")
        return SynthesizedAudio(wav_path=str(output_wav), sample_rate=48000)


class FakeAligner:
    def align(self, _wav_path, _language, _cancellation):
        return (
            AudioWordTiming(word="Hello", t_start=0, t_end=0.2),
            AudioWordTiming(word="world", t_start=0.3, t_end=0.6),
        )


class FakeTranscoder:
    def transcode(self, _wav_path, ogg_path, _bitrate, _tempo, _cancellation):
        ogg_path.parent.mkdir(parents=True, exist_ok=True)
        ogg_path.write_bytes(b"fake ogg")
        return 0.6


def _pdf(path: Path) -> Path:
    document = fitz.open()
    try:
        document.new_page(width=300, height=400)
        document.save(path)
    finally:
        document.close()
    return path


def _run(engine: PipelineEngine, step_id: StepId, params: dict[str, object], job: str):
    plan = engine.plan("book-1", step_id, params)
    assert not isinstance(plan, SkippedRun)
    return engine.execute(
        engine.begin(plan, job), lambda _progress, _message: None, CancellationToken()
    )


def test_explicit_auto_accept_unlocks_audio_revision(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "workspace")
    book = paths.book("book-1")
    book.mkdir(parents=True)
    source = _pdf(tmp_path / "source.pdf")
    target = book / "source.pdf"
    target.write_bytes(source.read_bytes())
    states = StateRepository(paths)
    states.create(PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256=file_sha256(target)))
    engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry(
            (
                PageProcessingStep(),
                FakeOcrStep(),
                AutoProofreadStep(),
                AudioStep(FakeTts(), FakeAligner(), FakeTranscoder()),
                ExportStep(),
            )
        ),
    )

    _run(engine, StepId.PAGES, {}, "12345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.OCR, {}, "22345678-1234-4234-8234-123456789abc")
    with pytest.raises(PipelineError, match="PROOFREAD_CONFIRMATION_REQUIRED"):
        _run(engine, StepId.PROOFREAD, {}, "32345678-1234-4234-8234-123456789abc")
    _run(
        engine,
        StepId.PROOFREAD,
        {"accept_ocr_draft": True},
        "42345678-1234-4234-8234-123456789abc",
    )
    success = _run(engine, StepId.AUDIO, {}, "52345678-1234-4234-8234-123456789abc")

    revision = book / success.output_root
    assert (revision / "ogg/s0001.ogg").read_bytes() == b"fake ogg"
    report = (revision / "word_timings.json").read_text(encoding="utf-8")
    assert '"audio_path": "ogg/s0001.ogg"' in report
    assert '"word": "Hello"' in report
    assert not (revision / "wav/s0001.wav").exists()

    regenerated = _run(
        engine,
        StepId.AUDIO,
        {"sentence_ids": ["s0001"], "base_audio_revision": success.revision_id},
        "62345678-1234-4234-8234-123456789abc",
    )
    assert regenerated.revision_id != success.revision_id
    assert (book / regenerated.output_root / "ogg/s0001.ogg").read_bytes() == b"fake ogg"

    workspace = AudioWorkspaceService(paths, states, ArtifactStore(paths)).load("book-1")
    assert workspace.audio_revision_id == regenerated.revision_id
    assert workspace.sentences[0].report is not None
    assert workspace.sentences[0].report.audio_path == "ogg/s0001.ogg"

    exported = _run(engine, StepId.EXPORT, {}, "72345678-1234-4234-8234-123456789abc")
    export_workspace = ExportWorkspaceService(paths, states, ArtifactStore(paths)).load("book-1")
    assert export_workspace.ready
    assert export_workspace.export_revision_id == exported.revision_id
    assert export_workspace.package.filename == "book-1.readalongbook"


def test_single_word_tts_input_gets_terminal_punctuation() -> None:
    assert AudioStep._tts_input("talk") == "talk."
    assert AudioStep._tts_input("Hello world.") == "Hello world."
