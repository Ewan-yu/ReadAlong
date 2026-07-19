from __future__ import annotations

from pathlib import Path, PurePosixPath

from app.models.audio import AudioGenerationReport, AudioParams
from app.models.audio_workspace import AudioWorkspaceResponse, AudioWorkspaceSentence
from app.models.errors import PipelineError
from app.models.ocr import OcrSentences
from app.models.pipeline import StepId, StepStatus, StepSuccess
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.paths import WorkspacePaths, ensure_within
from app.pipeline.state_repository import StateRepository


class AudioWorkspaceService:
    def __init__(self, paths: WorkspacePaths, states: StateRepository, artifacts: ArtifactStore) -> None:
        self.paths = paths
        self.states = states
        self.artifacts = artifacts
        self._verified: set[tuple[str, str]] = set()

    def load(self, book_id: str) -> AudioWorkspaceResponse:
        state = self.states.load(book_id)
        proofread = state.steps[StepId.PROOFREAD]
        if proofread.status is not StepStatus.DONE or proofread.success is None:
            raise PipelineError("PROOFREAD_NOT_READY", "请先发布 OCR 校对结果。", status_code=409)
        proofread_success = self._success(book_id, StepId.PROOFREAD, proofread.success, "校对结果")
        try:
            source = OcrSentences.model_validate_json(
                (self.paths.book(book_id) / proofread_success.output_root / "sentences_final.json").read_text(encoding="utf-8")
            )
        except (OSError, ValueError) as exc:
            raise PipelineError("PROOFREAD_ARTIFACT_INVALID", "校对句子表已损坏，请重新校对。", status_code=409) from exc

        reports = {}
        audio_revision_id: str | None = None
        params = AudioParams()
        voice_snapshot = None
        audio = state.steps[StepId.AUDIO]
        if audio.status is StepStatus.DONE and audio.success is not None:
            audio_success = self._success(book_id, StepId.AUDIO, audio.success, "音频结果")
            try:
                report = AudioGenerationReport.model_validate_json(
                    (self.paths.book(book_id) / audio_success.output_root / "tts_report.json").read_text(encoding="utf-8")
                )
            except (OSError, ValueError) as exc:
                raise PipelineError("AUDIO_ARTIFACT_INVALID", "音频报告已损坏，请重新生成全书。", status_code=409) from exc
            if report.source_proofread_revision != Path(proofread_success.output_root).name:
                raise PipelineError("AUDIO_SOURCE_STALE", "音频与当前校对结果不匹配，请重新生成全书。", status_code=409)
            reports = {item.sentence_id: item for item in report.sentences}
            params = report.params
            voice_snapshot = report.voice_snapshot
            audio_revision_id = audio_success.revision_id

        return AudioWorkspaceResponse(
            proofread_revision_id=proofread_success.revision_id,
            audio_revision_id=audio_revision_id,
            params=params,
            voice_snapshot=voice_snapshot,
            original_audio_path=state.source.original_audio_path,
            sentences=tuple(AudioWorkspaceSentence(sentence=item, report=reports.get(item.id)) for item in source.sentences),
        )

    def asset(self, book_id: str, revision_id: str, asset_path: str) -> Path:
        state = self.states.load(book_id)
        audio = state.steps[StepId.AUDIO]
        if audio.status is not StepStatus.DONE or audio.success is None or audio.success.revision_id != revision_id:
            raise PipelineError("AUDIO_REVISION_STALE", "音频结果已经更新，请刷新后继续试听。", status_code=409)
        success = self._success(book_id, StepId.AUDIO, audio.success, "音频结果")
        normalized = PurePosixPath(asset_path).as_posix()
        allowed = {item.path for item in success.outputs if item.path.startswith("ogg/")}
        if normalized not in allowed:
            raise PipelineError("AUDIO_ASSET_NOT_FOUND", "音频文件不存在。", status_code=404)
        root = self.paths.book(book_id) / success.output_root
        path = ensure_within(root, root / Path(*PurePosixPath(normalized).parts))
        if not path.is_file():
            raise PipelineError("AUDIO_ASSET_NOT_FOUND", "音频文件不存在。", status_code=404)
        return path

    def _success(self, book_id: str, step_id: StepId, success: StepSuccess, label: str) -> StepSuccess:
        key = (book_id, success.revision_id)
        if key not in self._verified and not self.artifacts.verify(book_id, step_id, success):
            raise PipelineError("AUDIO_ARTIFACT_INVALID", f"{label}不完整，请重新生成。", status_code=409)
        self._verified.add(key)
        return success
