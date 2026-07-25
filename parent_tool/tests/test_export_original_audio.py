from __future__ import annotations

import json
import zipfile
from pathlib import Path

import pytest
from pydantic import BaseModel, ConfigDict

from app.models.audio import (
    AudioGenerationReport,
    AudioSentenceReport,
    AudioWordTiming,
    TtsProviderKind,
)
from app.models.errors import PipelineError
from app.models.ocr import (
    BoundingBox,
    OcrPage,
    OcrSentence,
    OcrSentences,
    SentenceStatus,
)
from app.models.pages import (
    PageDecision,
    PageDetect,
    PageMode,
    PageOutput,
    PagePlan,
    PagePlanEntry,
    PageProcessParams,
    PageRegion,
    SourcePageSize,
)
from app.models.pipeline import PipelineState, StepId, StepResult, StepSuccess, utc_now
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import CancellationToken, StepRegistry
from app.pipeline.engine import PipelineEngine, RunPlan, SkippedRun
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.pipeline.steps import ExportStep
from app.services.export_workspace_service import ExportWorkspaceService


class FakeParams(BaseModel):
    model_config = ConfigDict(extra="forbid")


class FakePagesStep:
    step_id = StepId.PAGES
    implementation_version = "fake-pages-v1"
    params_model = FakeParams

    def run(self, context, _params):
        page = PageOutput(
            page_no=1,
            region=PageRegion.FULL,
            ocr_image="ocr/p0001.png",
            page_image="pages/p0001.webp",
            thumbnail="thumbnails/p0001.jpg",
            width=300,
            height=400,
        )
        plan = PagePlan(
            source_pdf_sha256=context.source_pdf_sha256,
            source_pdf_page_count=1,
            params=PageProcessParams(),
            pages=(
                PagePlanEntry(
                    source_pdf_page=1,
                    source_size_pt=SourcePageSize(width=300, height=400),
                    detect=PageDetect(suspect_split=False, confidence=100),
                    decision=PageDecision(mode=PageMode.KEEP, confirmed=True),
                    outputs=(page,),
                ),
            ),
        )
        for relative, content in (
            (page.ocr_image, b"png"),
            (page.page_image, b"webp"),
            (page.thumbnail, b"jpeg"),
        ):
            target = context.staging_dir / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        (context.staging_dir / "page_plan.json").write_text(
            plan.model_dump_json(), encoding="utf-8"
        )
        return StepResult(
            outputs=("page_plan.json", page.ocr_image, page.page_image, page.thumbnail)
        )


class FakeOcrStep:
    step_id = StepId.OCR
    implementation_version = "fake-ocr-v1"
    params_model = FakeParams

    def run(self, context, _params):
        (context.staging_dir / "ocr.txt").write_text("ready", encoding="utf-8")
        return StepResult(outputs=("ocr.txt",))


class FakeProofreadStep:
    step_id = StepId.PROOFREAD
    implementation_version = "fake-proofread-v1"
    params_model = FakeParams

    def run(self, context, _params):
        document = OcrSentences(
            source_pages_revision="r-pages-test",
            params={},
            pages=(
                OcrPage(
                    page_no=1,
                    ocr_image="ocr/p0001.png",
                    response_path="responses/p0001.json",
                    blocks_seen=1,
                    sentences_created=1,
                ),
            ),
            sentences=(
                OcrSentence(
                    id="s0001",
                    page_no=1,
                    seq=1,
                    text="Hello world.",
                    bbox=BoundingBox(x=0.1, y=0.1, width=0.5, height=0.1),
                    shared_bbox=False,
                    status=SentenceStatus.SENTENCE,
                ),
            ),
            confirmed_pages=(1,),
        )
        (context.staging_dir / "sentences_final.json").write_text(
            document.model_dump_json(), encoding="utf-8"
        )
        return StepResult(outputs=("sentences_final.json",))


class FakeAudioStep:
    step_id = StepId.AUDIO
    implementation_version = "fake-audio-v1"
    params_model = FakeParams

    def run(self, context, _params):
        report = AudioGenerationReport(
            source_proofread_revision=context.dependency_outputs[StepId.PROOFREAD].name,
            params={},
            sentences=(
                AudioSentenceReport(
                    sentence_id="s0001",
                    audio_path="ogg/s0001.ogg",
                    duration_seconds=0.8,
                    word_timing=(
                        AudioWordTiming(word="Hello", t_start=0, t_end=0.3),
                        AudioWordTiming(word="world", t_start=0.4, t_end=0.8),
                    ),
                    provider=TtsProviderKind.VOXCPM,
                ),
            ),
        )
        audio = context.staging_dir / "ogg" / "s0001.ogg"
        audio.parent.mkdir(parents=True, exist_ok=True)
        audio.write_bytes(b"fake ogg")
        (context.staging_dir / "tts_report.json").write_text(
            report.model_dump_json(), encoding="utf-8"
        )
        return StepResult(outputs=("tts_report.json", "ogg/s0001.ogg"))


class FakeMediaProbe:
    def __init__(self, duration_ms: int = 12_345) -> None:
        self.value = duration_ms
        self.fail = False
        self.calls: list[Path] = []

    def duration_ms(self, source: Path, _cancellation: CancellationToken) -> int:
        self.calls.append(source)
        if self.fail:
            raise PipelineError(
                "ORIGINAL_AUDIO_PROBE_FAILED",
                "synthetic probe failure",
                status_code=422,
            )
        return self.value


class FakePlaybackTranscoder:
    def __init__(self) -> None:
        self.calls: list[tuple[Path, Path]] = []

    def transcode_original_playback(
        self,
        source: Path,
        target: Path,
        *,
        cancellation: CancellationToken,
    ) -> None:
        self.calls.append((source, target))
        cancellation.raise_if_cancelled()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"OggS synthetic original playback")


def _run(
    engine: PipelineEngine,
    step_id: StepId,
    job_id: str,
    *,
    force: bool = False,
):
    plan = engine.plan("book-1", step_id, {}, force=force)
    assert not isinstance(plan, SkippedRun)
    return engine.execute(
        engine.begin(plan, job_id),
        lambda _progress, _message: None,
        CancellationToken(),
    )


def _ready_engine(
    tmp_path: Path,
    *,
    with_original: bool = True,
) -> tuple[PipelineEngine, StateRepository, WorkspacePaths, FakeMediaProbe, bytes]:
    paths = WorkspacePaths(tmp_path / "workspace")
    book = paths.book("book-1")
    book.mkdir(parents=True)
    source_pdf = book / "source.pdf"
    source_pdf.write_bytes(b"pdf source")
    original_bytes = b"ID3\x04\x00\x00synthetic original audio"
    original = book / "original_audio.mp3"
    if with_original:
        original.write_bytes(original_bytes)
    states = StateRepository(paths)
    states.create(
        PipelineState.new(
            book_id="book-1",
            pdf_path="source.pdf",
            pdf_sha256=file_sha256(source_pdf),
            original_audio_path="original_audio.mp3" if with_original else None,
            original_audio_sha256=file_sha256(original) if with_original else None,
        )
    )
    probe = FakeMediaProbe()
    engine = PipelineEngine(
        states,
        ArtifactStore(paths),
        StepRegistry(
            (
                FakePagesStep(),
                FakeOcrStep(),
                FakeProofreadStep(),
                FakeAudioStep(),
                ExportStep(probe, playback_transcoder=FakePlaybackTranscoder()),
            )
        ),
    )
    for step_id, job_id in (
        (StepId.PAGES, "12345678-1234-4234-8234-123456789abc"),
        (StepId.OCR, "22345678-1234-4234-8234-123456789abc"),
        (StepId.PROOFREAD, "32345678-1234-4234-8234-123456789abc"),
        (StepId.AUDIO, "42345678-1234-4234-8234-123456789abc"),
    ):
        _run(engine, step_id, job_id)
    return engine, states, paths, probe, original_bytes


def test_export_packages_original_audio_bytes_and_metadata(tmp_path: Path) -> None:
    engine, states, paths, probe, original_bytes = _ready_engine(tmp_path)

    success = _run(
        engine,
        StepId.EXPORT,
        "52345678-1234-4234-8234-123456789abc",
    )

    root = paths.book("book-1") / success.output_root
    bundle = root / "book-1.readalongbook"
    with zipfile.ZipFile(bundle) as archive:
        assert archive.read("original/source.mp3") == original_bytes
        manifest = json.loads(archive.read("manifest.json"))
    original = manifest["original_audio"]
    assert original == {
        "path": "original/source.mp3",
        "mime_type": "audio/mpeg",
        "size_bytes": len(original_bytes),
        "sha256": file_sha256(paths.book("book-1") / "original_audio.mp3"),
        "duration_ms": 12_345,
        "alignment_status": "raw",
        "playback": {
            "path": "original/playback.ogg",
            "mime_type": "audio/ogg",
            "size_bytes": len(b"OggS synthetic original playback"),
            "sha256": "839d67a2f261c1b77630e70e9f31e3cb1c8b0f5a224fccc256416fac1b6f6784",
        },
    }
    report = json.loads((root / "validation_report.json").read_text(encoding="utf-8"))
    assert report["original_audio"] == original
    assert len(probe.calls) == 1
    assert probe.calls[0].as_posix().endswith("/original/source.mp3")

    workspace = ExportWorkspaceService(paths, states, ArtifactStore(paths)).load("book-1")
    assert workspace.ready
    assert workspace.export_revision_id == success.revision_id
    assert workspace.package.original_audio is not None
    assert workspace.package.original_audio.duration_ms == 12_345
    assert next(item for item in workspace.checks if item.id == "original-audio").status == "pass"


def test_export_without_original_audio_keeps_legacy_package_shape(tmp_path: Path) -> None:
    engine, _states, paths, probe, _original_bytes = _ready_engine(
        tmp_path, with_original=False
    )

    success = _run(
        engine,
        StepId.EXPORT,
        "52345678-1234-4234-8234-123456789abc",
    )

    root = paths.book("book-1") / success.output_root
    with zipfile.ZipFile(root / "book-1.readalongbook") as archive:
        assert "original/source.mp3" not in archive.namelist()
        assert "original_audio" not in json.loads(archive.read("manifest.json"))
    assert probe.calls == []


@pytest.mark.parametrize(
    ("failure", "error_code"),
    (
        ("missing", "ORIGINAL_AUDIO_MISSING"),
        ("hash", "ORIGINAL_AUDIO_HASH_MISMATCH"),
        ("probe", "ORIGINAL_AUDIO_PROBE_FAILED"),
    ),
)
def test_failed_original_audio_rerun_preserves_old_export(
    tmp_path: Path,
    failure: str,
    error_code: str,
) -> None:
    engine, states, paths, probe, _original_bytes = _ready_engine(tmp_path)
    first = _run(
        engine,
        StepId.EXPORT,
        "52345678-1234-4234-8234-123456789abc",
    )
    source = paths.book("book-1") / "original_audio.mp3"
    if failure == "missing":
        source.unlink()
    elif failure == "hash":
        source.write_bytes(b"tampered")
    else:
        probe.fail = True

    plan = engine.plan("book-1", StepId.EXPORT, {}, force=True)
    assert isinstance(plan, RunPlan)
    prepared = engine.begin(plan, "62345678-1234-4234-8234-123456789abc")
    with pytest.raises(PipelineError) as caught:
        engine.execute(
            prepared,
            lambda _progress, _message: None,
            CancellationToken(),
        )

    assert caught.value.code == error_code
    current = states.load("book-1").steps[StepId.EXPORT]
    assert current.success == first
    assert (paths.book("book-1") / first.output_root / "book-1.readalongbook").is_file()


def test_export_fingerprint_changes_with_original_audio_hash(tmp_path: Path) -> None:
    engine, states, _paths, _probe, _original_bytes = _ready_engine(tmp_path)
    first = engine.plan("book-1", StepId.EXPORT, {})
    assert isinstance(first, RunPlan)

    def replace_hash(state: PipelineState) -> None:
        state.source = state.source.model_copy(
            update={"original_audio_sha256": "f" * 64}
        )

    states.update("book-1", replace_hash)
    second = engine.plan("book-1", StepId.EXPORT, {})
    assert isinstance(second, RunPlan)

    assert second.input_fingerprint != first.input_fingerprint


def test_confirmed_background_is_packaged_and_changes_export_fingerprint(
    tmp_path: Path,
) -> None:
    engine, states, paths, _probe, _original_bytes = _ready_engine(tmp_path)
    artifacts = engine.artifacts
    root = paths.revision("book-1", StepId.ORIGINAL_AUDIO, "r-background-12345678")
    root.mkdir(parents=True)
    background = root / "background.ogg"
    background.write_bytes(b"verified background")
    report = {
        "source_sha256": states.load("book-1").source.original_audio_sha256,
        "background": {
            "path": "background.ogg",
            "sha256": file_sha256(background),
            "duration_ms": 12_345,
        },
    }
    (root / "separation_report.json").write_text(json.dumps(report), encoding="utf-8")
    outputs, output_fingerprint = artifacts.build_manifest(
        root, ("background.ogg", "separation_report.json")
    )
    confirmed = StepSuccess(
        revision_id="r-background-12345678",
        output_root=root.relative_to(paths.book("book-1")).as_posix(),
        params_hash="a" * 64,
        input_fingerprint="b" * 64,
        output_fingerprint=output_fingerprint,
        outputs=outputs,
        completed_at=utc_now(),
    )

    def confirm(state: PipelineState) -> None:
        state.original_audio_review = state.original_audio_review.model_copy(
            update={"confirmed": confirmed, "confirmed_at": utc_now()}
        )

    states.update("book-1", confirm)
    before = engine.plan("book-1", StepId.EXPORT, {})
    assert isinstance(before, RunPlan)
    success = _run(engine, StepId.EXPORT, "52345678-1234-4234-8234-123456789abc")
    with zipfile.ZipFile(paths.book("book-1") / success.output_root / "book-1.readalongbook") as archive:
        assert archive.read("original/background.ogg") == b"verified background"
        original = json.loads(archive.read("manifest.json"))["original_audio"]
    assert original["background"]["path"] == "original/background.ogg"
    assert original["background"]["sha256"] == file_sha256(background)
    after = engine.plan("book-1", StepId.EXPORT, {})
    assert isinstance(after, SkippedRun)
    assert before.input_fingerprint == success.input_fingerprint
