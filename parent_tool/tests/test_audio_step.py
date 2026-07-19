from __future__ import annotations

from pathlib import Path

import fitz
import pytest
from pydantic import BaseModel, ConfigDict

from app.models.audio import AudioGenerationReport, AudioWordTiming, SynthesizedAudio
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


class CountingFakeTts(FakeTts):
    def __init__(self) -> None:
        self.calls: list[str] = []

    def synthesize(self, text, voice, output_wav, cancellation):
        self.calls.append(text)
        return super().synthesize(text, voice, output_wav, cancellation)


class FakeAligner:
    def align(self, _wav_path, _language, _cancellation):
        return (
            AudioWordTiming(word="Hello", t_start=0, t_end=0.2),
            AudioWordTiming(word="world", t_start=0.3, t_end=0.6),
        )


class PreviewThenExpectedAligner:
    def __init__(self) -> None:
        self.calls = 0

    def align(self, _wav_path, _language, _cancellation):
        self.calls += 1
        words = (
            ("Hello", "let's", "enjoy", "this", "story", "together")
            if self.calls == 1
            else ("Hello", "world")
        )
        return tuple(
            AudioWordTiming(word=word, t_start=index * 0.2, t_end=(index + 1) * 0.2)
            for index, word in enumerate(words)
        )


class DuplicateWordOcrStep:
    step_id = StepId.OCR
    implementation_version = "fake-duplicate-word-ocr-v1"
    params_model = FakeParams

    def run(self, context, _params):
        document = OcrSentences(
            source_pages_revision="r-pages",
            params={},
            pages=(),
            sentences=tuple(
                OcrSentence(
                    id=f"s{index:04d}",
                    page_no=1,
                    seq=index,
                    text=text,
                    bbox=BoundingBox(x=0.1, y=0.1 * index, width=0.3, height=0.08),
                    shared_bbox=False,
                    status=SentenceStatus.SENTENCE,
                )
                for index, text in enumerate(("shirt", "Shirt!", "Dress up."), start=1)
            ),
        )
        (context.staging_dir / "sentences.json").write_text(document.model_dump_json(), encoding="utf-8")
        return StepResult(outputs=("sentences.json",))


class FakeTranscoder:
    def transcode(self, _wav_path, ogg_path, _bitrate, _tempo, _cancellation):
        ogg_path.parent.mkdir(parents=True, exist_ok=True)
        ogg_path.write_bytes(b"fake ogg")
        # The default tempo is 0.9, so the final asset is longer than the
        # source-alignment timeline returned by FakeAligner.
        return 0.7


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
    assert (revision / "reference/voice-reference.wav").is_file()
    original_voice_reference = (revision / "reference/voice-reference.wav").read_bytes()
    report = (revision / "word_timings.json").read_text(encoding="utf-8")
    assert '"audio_path": "ogg/s0001.ogg"' in report
    assert '"word": "Hello"' in report
    assert '"voice_snapshot"' in report
    assert file_sha256(revision / "reference/voice-reference.wav") in report
    assert not (revision / "wav/s0001.wav").exists()

    regenerated = _run(
        engine,
        StepId.AUDIO,
        {"sentence_ids": ["s0001"], "base_audio_revision": success.revision_id},
        "62345678-1234-4234-8234-123456789abc",
    )
    assert regenerated.revision_id != success.revision_id
    assert (book / regenerated.output_root / "ogg/s0001.ogg").read_bytes() == b"fake ogg"
    assert (book / regenerated.output_root / "reference/voice-reference.wav").read_bytes() == original_voice_reference

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
    assert AudioStep._tts_input("talk") == "talk..."
    assert AudioStep._tts_input("Hello world.") == "Hello world."


def test_reference_preview_transcript_is_retried_but_normal_alignment_drift_is_not() -> None:
    preview = tuple(
        AudioWordTiming(word=word, t_start=index * 0.2, t_end=(index + 1) * 0.2)
        for index, word in enumerate(("Hello", "let's", "enjoy", "this", "story", "together"))
    )
    merged_name = (AudioWordTiming(word="Annegaos", t_start=0, t_end=0.8),)

    assert AudioStep._is_reference_prompt_leakage("Ana Goes", preview)
    assert not AudioStep._is_reference_prompt_leakage("Hello, let's enjoy this story together.", preview)
    assert not AudioStep._is_reference_prompt_leakage("Ana Goes", merged_name)


def test_audio_step_retries_a_reference_preview_leak_before_publishing(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "workspace")
    book = paths.book("book-1")
    book.mkdir(parents=True)
    source = _pdf(tmp_path / "source.pdf")
    target = book / "source.pdf"
    target.write_bytes(source.read_bytes())
    states = StateRepository(paths)
    states.create(PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256=file_sha256(target)))
    tts = CountingFakeTts()
    engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry(
            (
                PageProcessingStep(),
                FakeOcrStep(),
                AutoProofreadStep(),
                AudioStep(tts, PreviewThenExpectedAligner(), FakeTranscoder()),
                ExportStep(),
            )
        ),
    )

    _run(engine, StepId.PAGES, {}, "12345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.OCR, {}, "22345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.PROOFREAD, {"accept_ocr_draft": True}, "32345678-1234-4234-8234-123456789abc")
    result = _run(engine, StepId.AUDIO, {}, "42345678-1234-4234-8234-123456789abc")

    report = AudioGenerationReport.model_validate_json(
        (book / result.output_root / "tts_report.json").read_text(encoding="utf-8")
    )
    assert len(tts.calls) == 3  # anchor, initial sentence, safe retry
    assert report.sentences[0].audio_path == "ogg/s0001.ogg"
    assert report.sentences[0].error_code is None


def test_full_book_reuses_duplicate_isolated_word_audio(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "workspace")
    book = paths.book("book-1")
    book.mkdir(parents=True)
    source = _pdf(tmp_path / "source.pdf")
    target = book / "source.pdf"
    target.write_bytes(source.read_bytes())
    states = StateRepository(paths)
    states.create(PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256=file_sha256(target)))
    tts = CountingFakeTts()
    engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry((PageProcessingStep(), DuplicateWordOcrStep(), AutoProofreadStep(), AudioStep(tts, FakeAligner(), FakeTranscoder()), ExportStep())),
    )

    _run(engine, StepId.PAGES, {}, "12345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.OCR, {}, "22345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.PROOFREAD, {"accept_ocr_draft": True}, "32345678-1234-4234-8234-123456789abc")
    result = _run(engine, StepId.AUDIO, {}, "42345678-1234-4234-8234-123456789abc")

    report = AudioGenerationReport.model_validate_json((book / result.output_root / "tts_report.json").read_text(encoding="utf-8"))
    assert len(tts.calls) == 4  # anchor + carrier/fallback for shirt + one ordinary sentence
    assert report.sentences[0].duration_seconds == report.sentences[1].duration_seconds
    assert report.sentences[0].word_timing == report.sentences[1].word_timing


def test_single_english_word_uses_context_carrier_and_selects_target_timing() -> None:
    carrier = AudioStep._word_carrier_input("Family!")
    timings = (
        AudioWordTiming(word="The", t_start=0.1, t_end=0.25),
        AudioWordTiming(word="word", t_start=0.25, t_end=0.5),
        AudioWordTiming(word="is", t_start=0.5, t_end=0.62),
        AudioWordTiming(word="family.", t_start=0.62, t_end=1.05),
    )

    assert carrier == "The word is family."
    assert AudioStep._uses_word_carrier("Family!", "en") is True
    assert AudioStep._uses_word_carrier("My family", "en") is False
    assert AudioStep._carrier_target_timing("Family!", carrier, timings) == timings[-1]


def test_carrier_target_is_rejected_when_alignment_does_not_match() -> None:
    timings = (AudioWordTiming(word="family", t_start=0.2, t_end=0.6),)

    assert AudioStep._carrier_target_timing("family", "The word is family.", timings) is None
