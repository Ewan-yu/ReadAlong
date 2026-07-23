from __future__ import annotations

from pathlib import Path

from app.models.pipeline import PipelineState, StepId, StepResult, StepStatus
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import CancellationToken, StepRegistry
from app.pipeline.engine import PipelineEngine, SkippedRun
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.services.original_audio_review_service import OriginalAudioReviewService


class EmptyParams:
    @classmethod
    def model_validate(cls, _raw):
        return cls()

    def model_dump(self, *, mode: str):
        return {}


class FakeProofread:
    step_id = StepId.PROOFREAD
    implementation_version = "proofread-test-v1"
    params_model = EmptyParams

    def run(self, context, _params):
        (context.staging_dir / "sentences_final.json").write_text("{}", encoding="utf-8")
        return StepResult(outputs=("sentences_final.json",))


class FakeStage:
    implementation_version = "stage-test-v1"
    params_model = EmptyParams

    def __init__(self, step_id: StepId) -> None:
        self.step_id = step_id

    def run(self, context, _params):
        (context.staging_dir / "result.json").write_text("{}", encoding="utf-8")
        return StepResult(outputs=("result.json",))


class FakeOriginalAudio:
    step_id = StepId.ORIGINAL_AUDIO
    implementation_version = "original-test-v1"
    params_model = EmptyParams

    def run(self, context, _params):
        for name in ("background.ogg", "preview/vocals.ogg", "preview/background.ogg"):
            target = context.staging_dir / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(name.encode())
        for name in ("source_report.json", "separation_report.json", "waveform/original.json", "waveform/vocals.json", "waveform/background.json"):
            target = context.staging_dir / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("{}", encoding="utf-8")
        return StepResult(outputs=("background.ogg", "preview/vocals.ogg", "preview/background.ogg", "source_report.json", "separation_report.json", "waveform/original.json", "waveform/vocals.json", "waveform/background.json"))


def _run(engine: PipelineEngine, step: StepId, job: str, *, force: bool = False):
    plan = engine.plan("book-1", step, {}, force=force)
    assert not isinstance(plan, SkippedRun)
    return engine.execute(engine.begin(plan, job), lambda _progress, _message: None, CancellationToken())


def test_candidate_requires_explicit_confirmation_and_is_promoted(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path)
    states = StateRepository(paths)
    book = paths.book("book-1")
    book.mkdir(parents=True)
    states.create(PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64, original_audio_path="original_audio.mp3", original_audio_sha256="b" * 64))
    engine = PipelineEngine(states, ArtifactStore(paths), StepRegistry((FakeStage(StepId.PAGES), FakeStage(StepId.OCR), FakeProofread(), FakeOriginalAudio())))
    _run(engine, StepId.PAGES, "02345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.OCR, "11345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.PROOFREAD, "12345678-1234-4234-8234-123456789abc")
    candidate = _run(engine, StepId.ORIGINAL_AUDIO, "22345678-1234-4234-8234-123456789abc")
    assert candidate.output_root.startswith("06_original_audio/candidates/")
    assert states.load("book-1").original_audio_review.confirmed is None

    published = OriginalAudioReviewService(states, ArtifactStore(paths)).confirm_current("book-1")

    assert published.output_root.startswith("06_original_audio/revisions/")
    state = states.load("book-1")
    assert state.original_audio_review.confirmed == published
    assert (book / published.output_root / "background.ogg").is_file()
    assert state.steps[StepId.ORIGINAL_AUDIO].status is StepStatus.DONE

    _run(
        engine,
        StepId.PROOFREAD,
        "32345678-1234-4234-8234-123456789abc",
        force=True,
    )
    stale = states.load("book-1")
    assert stale.steps[StepId.ORIGINAL_AUDIO].status is StepStatus.STALE
    assert stale.original_audio_review.confirmed is None
