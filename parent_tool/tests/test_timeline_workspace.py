from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from app.models.errors import PipelineError
from app.models.ocr import BoundingBox, OcrPage, OcrSentence, OcrSentences, SentenceStatus
from app.models.original_timeline import (
    ManualTimelineSentence,
    OriginalTimeline,
    OriginalTimelineParams,
    OriginalTimelineSentence,
    OriginalTimelineSource,
    OriginalTimelineWord,
)
from app.models.pipeline import InvalidationReason, PipelineState, StepId, StepResult, StepState, StepStatus, utc_now
from app.models.timeline_workspace import TimelineReviewUpdateRequest
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import CancellationToken, StepRegistry
from app.pipeline.engine import PipelineEngine, SkippedRun
from app.pipeline.hashing import file_sha256
from app.pipeline.original_timeline import GENERATION_REPORT_PATH, TIMELINE_PATH, write_timeline
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.pipeline.steps.original_timeline import OriginalTimelineStep
from app.pipeline.timeline_review import load_confirmed_ids
from app.services.original_audio_review_service import OriginalAudioReviewService
from app.services.timeline_workspace_service import TimelineWorkspaceService


class EmptyParams:
    @classmethod
    def model_validate(cls, _raw):
        return cls()

    def model_dump(self, *, mode: str):
        return {}


def _proofread_sentences() -> OcrSentences:
    def sentence(identifier: str, page_no: int, seq: int, text: str) -> OcrSentence:
        return OcrSentence(
            id=identifier,
            page_no=page_no,
            seq=seq,
            text=text,
            bbox=BoundingBox(x=0, y=0, width=.5, height=.1),
            shared_bbox=False,
            status=SentenceStatus.SENTENCE,
        )

    return OcrSentences(
        source_pages_revision="r-pages-12345678",
        params={},
        pages=(
            OcrPage(page_no=1, ocr_image="ocr/p0001.png", response_path="responses/p0001.json", blocks_seen=2, sentences_created=2),
            OcrPage(page_no=2, ocr_image="ocr/p0002.png", response_path="responses/p0002.json", blocks_seen=1, sentences_created=1),
        ),
        sentences=(
            sentence("s0001", 1, 1, "Hello world."),
            sentence("s0002", 1, 2, "Skipped cover words."),
            sentence("s0003", 2, 3, "Good night."),
        ),
        confirmed_pages=(1, 2),
    )


def _timeline(*, proofread_revision: str, original_audio_revision: str) -> OriginalTimeline:
    def entry(identifier: str, page_no: int, seq: int, text: str, words: tuple[tuple[str, int, int], ...], start_ms: int) -> OriginalTimelineSentence:
        return OriginalTimelineSentence(
            sentence_id=identifier,
            page_no=page_no,
            seq=seq,
            text=text,
            start_ms=start_ms,
            end_ms=words[-1][2],
            words=tuple(
                OriginalTimelineWord(seq=index, text=word, start_ms=begin, end_ms=end)
                for index, (word, begin, end) in enumerate(words, start=1)
            ),
        )

    return OriginalTimeline(
        source=OriginalTimelineSource(
            proofread_revision=proofread_revision,
            original_audio_revision=original_audio_revision,
            original_audio_sha256="a" * 64,
            vocal_sha256="b" * 64,
        ),
        sentences=(
            entry("s0001", 1, 1, "Hello world.", (("hello", 0, 300), ("world", 400, 800)), 0),
            entry("s0003", 2, 3, "Good night.", (("good", 1000, 1300), ("night", 1400, 1800)), 1000),
        ),
        audio_sha256="a" * 64,
        duration_ms=2_000,
    )


def _generation_report() -> dict:
    return {
        "schema_version": 1,
        "strategy": "discovery_projection",
        "whisper_model": "tiny",
        "recognized_word_count": 6,
        "narrated_sentence_count": 2,
        "omitted_sentence_count": 1,
        "omitted": [
            {
                "sentence_id": "s0002",
                "reason": "no_similar_match",
                "detail": None,
                "previous_matched_id": "s0001",
                "next_matched_id": "s0003",
                "nearby_asr": ["hello", "world"],
            }
        ],
    }


class FakeProofread:
    step_id = StepId.PROOFREAD
    implementation_version = "proofread-test-v1"
    params_model = EmptyParams

    def run(self, context, _params):
        (context.staging_dir / "sentences_final.json").write_text(
            _proofread_sentences().model_dump_json(indent=2), encoding="utf-8"
        )
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


class FakeTimeline:
    step_id = StepId.ORIGINAL_TIMELINE
    implementation_version = "timeline-test-v1"
    params_model = EmptyParams

    def run(self, context, _params):
        timeline = _timeline(
            proofread_revision=context.dependency_outputs[StepId.PROOFREAD].name,
            original_audio_revision=context.confirmed_original_audio_output.name,  # type: ignore[union-attr]
        ).model_copy(
            update={
                "audio_sha256": context.source_original_audio_sha256,
            }
        )
        timeline = timeline.model_copy(
            update={
                "source": timeline.source.model_copy(
                    update={
                        "original_audio_sha256": context.source_original_audio_sha256,
                        "vocal_sha256": hashlib.sha256(b"vocals-bytes").hexdigest(),
                    }
                )
            }
        )
        write_timeline(context.staging_dir / TIMELINE_PATH, timeline)
        report_path = context.staging_dir / GENERATION_REPORT_PATH
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(_generation_report(), indent=2), encoding="utf-8")
        return StepResult(
            outputs=(TIMELINE_PATH, GENERATION_REPORT_PATH),
            summary={"alignment_strategy": "discovery_projection"},
        )


def _run(engine: PipelineEngine, step: StepId, job: str, *, force: bool = False, params: dict | None = None):
    plan = engine.plan("book-1", step, params or {}, force=force)
    assert not isinstance(plan, SkippedRun)
    return engine.execute(engine.begin(plan, job), lambda _progress, _message: None, CancellationToken())


def _prepared_service(tmp_path: Path) -> TimelineWorkspaceService:
    paths = WorkspacePaths(tmp_path)
    states = StateRepository(paths)
    book = paths.book("book-1")
    book.mkdir(parents=True)
    states.create(PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64, original_audio_path="original_audio.mp3", original_audio_sha256="b" * 64))
    engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry(
            (
                FakeStage(StepId.PAGES),
                FakeStage(StepId.OCR),
                FakeProofread(),
                FakeOriginalAudio(),
                FakeTimeline(),
            )
        ),
    )
    _run(engine, StepId.PAGES, "02345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.OCR, "11345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.PROOFREAD, "12345678-1234-4234-8234-123456789abc")
    _run(engine, StepId.ORIGINAL_AUDIO, "22345678-1234-4234-8234-123456789abc")
    review = OriginalAudioReviewService(states, ArtifactStore(paths))
    review.confirm_current("book-1")
    _run(engine, StepId.ORIGINAL_TIMELINE, "27345678-1234-4234-8234-123456789abc")
    return TimelineWorkspaceService(paths, states, ArtifactStore(paths))


def test_workspace_joins_proofread_script_with_timeline_and_report(tmp_path: Path) -> None:
    service = _prepared_service(tmp_path)

    workspace = service.workspace("book-1")

    assert workspace.available is True
    assert workspace.status == "ready"
    assert workspace.whisper_model == "tiny"
    assert workspace.alignment_strategy == "discovery_projection"
    assert workspace.duration_ms == 2_000
    assert (workspace.matched_count, workspace.suspect_missing_count, workspace.confirmed_excluded_count) == (2, 1, 0)
    rows = {row.sentence_id: row for row in workspace.sentences}
    assert rows["s0001"].status == "matched"
    assert rows["s0001"].source == "asr"
    assert (rows["s0001"].start_ms, rows["s0001"].end_ms) == (0, 800)
    assert rows["s0002"].status == "suspect_missing"
    assert rows["s0002"].reason == "no_similar_match"
    assert rows["s0002"].previous_matched_id == "s0001"
    assert rows["s0002"].next_matched_id == "s0003"
    assert rows["s0002"].nearby_asr == ("hello", "world")
    assert rows["s0003"].status == "matched"


def test_review_confirmation_persists_and_survives_reload(tmp_path: Path) -> None:
    service = _prepared_service(tmp_path)
    service.update_review("book-1", TimelineReviewUpdateRequest(confirmed_not_narrated=("s0002",)))

    workspace = service.workspace("book-1")

    assert workspace.confirmed_excluded_count == 1
    assert workspace.suspect_missing_count == 0
    assert workspace.matched_count == 2
    assert workspace.sentences[1].status == "confirmed_excluded"
    store = json.loads((WorkspacePaths(tmp_path).book("book-1") / "timeline_review.json").read_text(encoding="utf-8"))
    assert store["confirmed_not_narrated"] == ["s0002"]


def test_review_rejects_unknown_sentence_ids(tmp_path: Path) -> None:
    service = _prepared_service(tmp_path)

    with pytest.raises(PipelineError) as caught:
        service.update_review(
            "book-1", TimelineReviewUpdateRequest(confirmed_not_narrated=("s9999",))
        )
    assert caught.value.code == "TIMELINE_REVIEW_SENTENCE_UNKNOWN"


def test_workspace_marks_stale_timeline_with_message(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path)
    states = StateRepository(paths)
    service = _prepared_service(tmp_path)

    def mutate(updated) -> None:
        timeline = updated.steps[StepId.ORIGINAL_TIMELINE]
        assert timeline.success is not None
        updated.steps[StepId.ORIGINAL_TIMELINE] = StepState(
            status=StepStatus.STALE,
            success=timeline.success,
            last_attempt=timeline.last_attempt,
            stale_reason=InvalidationReason(
                source_step=StepId.PROOFREAD,
                old_output_fingerprint=timeline.success.output_fingerprint,
                new_output_fingerprint="c" * 64,
                reason="test",
                invalidated_at=utc_now(),
            ),
        )

    states.update("book-1", mutate)
    workspace = service.workspace("book-1")

    assert workspace.status == "stale"
    assert workspace.message is not None
    assert workspace.matched_count == 2


def test_workspace_before_timeline_generation(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path)
    states = StateRepository(paths)
    book = paths.book("book-1")
    book.mkdir(parents=True)
    states.create(PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64, original_audio_path="original_audio.mp3", original_audio_sha256="b" * 64))
    service = TimelineWorkspaceService(paths, states, ArtifactStore(paths))

    workspace = service.workspace("book-1")

    assert workspace.available is True
    assert workspace.status == "not_generated"
    assert workspace.sentences == ()


class FakeOriginalAudioWithReport:
    """Separation candidate whose report hashes match the workspace source."""

    step_id = StepId.ORIGINAL_AUDIO
    implementation_version = "original-report-test-v1"
    params_model = EmptyParams

    def run(self, context, _params):
        vocals = b"vocals-bytes"
        for name in ("background.ogg", "preview/vocals.ogg", "preview/background.ogg"):
            target = context.staging_dir / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(vocals if name.endswith("vocals.ogg") else name.encode())
        report = {
            "vocals_preview": {"sha256": hashlib.sha256(vocals).hexdigest()},
            "source_sha256": context.source_original_audio_sha256,
        }
        (context.staging_dir / "separation_report.json").write_text(json.dumps(report), encoding="utf-8")
        for name in ("source_report.json", "waveform/original.json", "waveform/vocals.json", "waveform/background.json"):
            target = context.staging_dir / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("{}", encoding="utf-8")
        return StepResult(outputs=("background.ogg", "preview/vocals.ogg", "preview/background.ogg", "source_report.json", "separation_report.json", "waveform/original.json", "waveform/vocals.json", "waveform/background.json"))


class FakeProbe:
    def duration_ms(self, path, cancellation) -> int:
        return 2_000


def test_manual_correction_requires_a_generated_baseline(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path)
    states = StateRepository(paths)
    book = paths.book("book-1")
    book.mkdir(parents=True)
    source_file = book / "original_audio.mp3"
    source_file.write_bytes(b"fake-original-audio")
    states.create(PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64, original_audio_path="original_audio.mp3", original_audio_sha256=file_sha256(source_file)))
    base_engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry(
            (
                FakeStage(StepId.PAGES),
                FakeStage(StepId.OCR),
                FakeProofread(),
                FakeOriginalAudioWithReport(),
            )
        ),
    )
    _run(base_engine, StepId.PAGES, "02345678-1234-4234-8234-123456789abc")
    _run(base_engine, StepId.OCR, "11345678-1234-4234-8234-123456789abc")
    _run(base_engine, StepId.PROOFREAD, "12345678-1234-4234-8234-123456789abc")
    _run(base_engine, StepId.ORIGINAL_AUDIO, "22345678-1234-4234-8234-123456789abc")
    OriginalAudioReviewService(states, ArtifactStore(paths)).confirm_current("book-1")

    engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry((OriginalTimelineStep(object(), FakeProbe()),)),  # type: ignore[arg-type]
    )
    params = OriginalTimelineParams(
        manual_sentences=(ManualTimelineSentence(sentence_id="s0001", start_ms=0, end_ms=800),)
    )
    with pytest.raises(PipelineError) as caught:
        _run(
            engine,
            StepId.ORIGINAL_TIMELINE,
            "32345678-1234-4234-8234-123456789abc",
            params=params.model_dump(mode="json"),
        )
    assert caught.value.code == "ORIGINAL_TIMELINE_MANUAL_BASE_MISSING"


def test_manual_correction_publishes_parent_reviewed_table(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path)
    states = StateRepository(paths)
    book = paths.book("book-1")
    book.mkdir(parents=True)
    source_file = book / "original_audio.mp3"
    source_file.write_bytes(b"fake-original-audio")
    states.create(PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64, original_audio_path="original_audio.mp3", original_audio_sha256=file_sha256(source_file)))
    base_engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry(
            (
                FakeStage(StepId.PAGES),
                FakeStage(StepId.OCR),
                FakeProofread(),
                FakeOriginalAudioWithReport(),
                FakeTimeline(),
            )
        ),
    )
    _run(base_engine, StepId.PAGES, "02345678-1234-4234-8234-123456789abc")
    _run(base_engine, StepId.OCR, "11345678-1234-4234-8234-123456789abc")
    _run(base_engine, StepId.PROOFREAD, "12345678-1234-4234-8234-123456789abc")
    _run(base_engine, StepId.ORIGINAL_AUDIO, "22345678-1234-4234-8234-123456789abc")
    OriginalAudioReviewService(states, ArtifactStore(paths)).confirm_current("book-1")
    baseline = _run(base_engine, StepId.ORIGINAL_TIMELINE, "27345678-1234-4234-8234-123456789abc")

    engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry((OriginalTimelineStep(object(), FakeProbe()),)),  # type: ignore[arg-type]
    )
    params = OriginalTimelineParams(
        manual_sentences=(
            ManualTimelineSentence(sentence_id="s0001", start_ms=0, end_ms=800),
            ManualTimelineSentence(sentence_id="s0002", start_ms=850, end_ms=950),
            ManualTimelineSentence(sentence_id="s0003", start_ms=1000, end_ms=1900),
        )
    )
    corrected = engine.execute(
        engine.begin(engine.plan("book-1", StepId.ORIGINAL_TIMELINE, params.model_dump(mode="json")), "32345678-1234-4234-8234-123456789abc"),
        lambda _progress, _message: None,
        CancellationToken(),
    )

    assert corrected.revision_id != baseline.revision_id
    service = TimelineWorkspaceService(paths, states, ArtifactStore(paths))
    workspace = service.workspace("book-1")
    assert workspace.status == "ready"
    assert workspace.alignment_strategy == "manual_correction"
    assert workspace.matched_count == 3
    rows = {row.sentence_id: row for row in workspace.sentences}
    assert rows["s0001"].source == "asr"  # unchanged boundaries keep ASR words
    assert rows["s0002"].source == "manual_added"
    assert rows["s0003"].source == "manual_adjusted"
    # s0003 moved to 1000-1900: words re-synthesised inside the new span.
    timeline = OriginalTimeline.model_validate_json(
        (paths.book("book-1") / corrected.output_root / TIMELINE_PATH).read_text(encoding="utf-8")
    )
    s0003 = timeline.sentences[-1]
    assert (s0003.start_ms, s0003.end_ms) == (1000, 1900)
    assert all(word.end_ms - word.start_ms >= 30 for word in s0003.words)
    assert [word.text for word in s0003.words] == ["good", "night"]
    # Excluding nothing still leaves the review store untouched.
    assert load_confirmed_ids(book) == set()


def test_manual_correction_remembers_excluded_sentences(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path)
    states = StateRepository(paths)
    book = paths.book("book-1")
    book.mkdir(parents=True)
    source_file = book / "original_audio.mp3"
    source_file.write_bytes(b"fake-original-audio")
    states.create(PipelineState.new(book_id="book-1", pdf_path="source.pdf", pdf_sha256="a" * 64, original_audio_path="original_audio.mp3", original_audio_sha256=file_sha256(source_file)))
    base_engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry(
            (
                FakeStage(StepId.PAGES),
                FakeStage(StepId.OCR),
                FakeProofread(),
                FakeOriginalAudioWithReport(),
                FakeTimeline(),
            )
        ),
    )
    _run(base_engine, StepId.PAGES, "02345678-1234-4234-8234-123456789abc")
    _run(base_engine, StepId.OCR, "11345678-1234-4234-8234-123456789abc")
    _run(base_engine, StepId.PROOFREAD, "12345678-1234-4234-8234-123456789abc")
    _run(base_engine, StepId.ORIGINAL_AUDIO, "22345678-1234-4234-8234-123456789abc")
    OriginalAudioReviewService(states, ArtifactStore(paths)).confirm_current("book-1")
    _run(base_engine, StepId.ORIGINAL_TIMELINE, "27345678-1234-4234-8234-123456789abc")

    engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry((OriginalTimelineStep(object(), FakeProbe()),)),  # type: ignore[arg-type]
    )
    params = OriginalTimelineParams(
        manual_sentences=(
            ManualTimelineSentence(sentence_id="s0001", start_ms=0, end_ms=800),
            ManualTimelineSentence(sentence_id="s0003", start_ms=1000, end_ms=1800),
        )
    )
    engine.execute(
        engine.begin(engine.plan("book-1", StepId.ORIGINAL_TIMELINE, params.model_dump(mode="json")), "32345678-1234-4234-8234-123456789abc"),
        lambda _progress, _message: None,
        CancellationToken(),
    )

    assert load_confirmed_ids(book) == {"s0002"}
    service = TimelineWorkspaceService(paths, states, ArtifactStore(paths))
    workspace = service.workspace("book-1")
    assert workspace.sentences[1].status == "confirmed_excluded"


def test_manual_words_distribute_weighted_and_reject_short_spans() -> None:
    words = OriginalTimelineStep._manual_words("Good night.", 1000, 1900, sentence_id="s0003")
    assert [word.text for word in words] == ["good", "night"]
    assert [word.seq for word in words] == [1, 2]
    assert words[0].start_ms == 1000
    assert words[-1].end_ms == 1900
    assert all(word.end_ms - word.start_ms >= 30 for word in words)

    with pytest.raises(PipelineError) as caught:
        OriginalTimelineStep._manual_words("One two three four.", 0, 100, sentence_id="s0009")
    assert caught.value.code == "ORIGINAL_TIMELINE_MANUAL_SPAN_TOO_SHORT"
