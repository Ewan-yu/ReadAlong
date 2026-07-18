from __future__ import annotations

import json
from pathlib import Path, PurePosixPath

from app.models.audio import AudioGenerationReport
from app.models.errors import PipelineError
from app.models.export_workspace import ExportCheck, ExportPackageInfo, ExportWorkspaceResponse
from app.models.ocr import OcrSentences
from app.models.pages import PagePlan
from app.models.pipeline import StepId, StepStatus, StepSuccess
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.paths import WorkspacePaths, ensure_within
from app.pipeline.state_repository import StateRepository


class ExportWorkspaceService:
    def __init__(self, paths: WorkspacePaths, states: StateRepository, artifacts: ArtifactStore) -> None:
        self.paths = paths
        self.states = states
        self.artifacts = artifacts
        self._verified: set[tuple[str, str]] = set()

    def load(self, book_id: str) -> ExportWorkspaceResponse:
        state = self.states.load(book_id)
        checks: list[ExportCheck] = []
        pages = self._load_pages(book_id, state.steps[StepId.PAGES].status, state.steps[StepId.PAGES].success, checks)
        sentences = self._load_sentences(book_id, state.steps[StepId.PROOFREAD].status, state.steps[StepId.PROOFREAD].success, checks)
        audio = self._load_audio(book_id, state.steps[StepId.AUDIO].status, state.steps[StepId.AUDIO].success, checks)
        page_count = len(tuple(output for entry in pages.pages for output in entry.outputs)) if pages else 0
        sentence_count = len(sentences.sentences) if sentences else 0
        timing_count = sum(item.word_timing is not None for item in audio.sentences) if audio else 0
        provider_counts: dict[str, int] = {}
        if audio:
            for item in audio.sentences:
                if item.provider:
                    provider_counts[item.provider.value] = provider_counts.get(item.provider.value, 0) + 1
            missing = [item.sentence_id for item in audio.sentences if not item.audio_path]
            if missing:
                checks.append(ExportCheck(id="audio", label="TTS 音频", status="error", detail=f"{len(missing)} 句缺少音频，不能导出。"))
            else:
                checks.append(ExportCheck(id="audio", label="TTS 音频", status="pass", detail=f"{len(audio.sentences)} 句 Ogg 音频完整。"))
            no_timing = len(audio.sentences) - timing_count
            checks.append(ExportCheck(id="timing", label="词级时间戳", status="warning" if no_timing else "pass", detail=f"{timing_count} 句具备词级时间；{no_timing} 句将使用整句字幕。"))
            proofread = state.steps[StepId.PROOFREAD].success
            if proofread and audio.source_proofread_revision != Path(proofread.output_root).name:
                checks.append(ExportCheck(id="audio-source", label="语音来源", status="error", detail="音频基于旧校对结果，请重新生成全书语音。"))
        filename = f"{book_id}.readalongbook"
        export_revision_id: str | None = None
        size_bytes: int | None = None
        sha256: str | None = None
        exported = state.steps[StepId.EXPORT]
        if exported.status is StepStatus.DONE and exported.success is not None and self._verify(book_id, StepId.EXPORT, exported.success):
            export_revision_id = exported.success.revision_id
            root = self.paths.book(book_id) / exported.success.output_root
            try:
                report = json.loads((root / "validation_report.json").read_text(encoding="utf-8"))
                size_bytes, sha256 = int(report["size_bytes"]), str(report["sha256"])
                checks.append(ExportCheck(id="bundle", label="资源包校验", status="pass", detail="已生成并通过 manifest、页面、音频与 alignment 校验。"))
            except (OSError, ValueError, KeyError, TypeError):
                checks.append(ExportCheck(id="bundle", label="资源包校验", status="error", detail="导出报告已损坏，请重新生成资源包。"))
                export_revision_id = None
        ready = bool(pages and sentences and audio and not any(item.status == "error" for item in checks))
        return ExportWorkspaceResponse(
            ready=ready,
            suggested_title=book_id.replace("-", " ").title(),
            checks=tuple(checks),
            package=ExportPackageInfo(filename=filename, page_count=page_count, sentence_count=sentence_count, word_timing_sentence_count=timing_count, audio_provider_counts=provider_counts, size_bytes=size_bytes, sha256=sha256),
            export_revision_id=export_revision_id,
        )

    def bundle(self, book_id: str, revision_id: str) -> Path:
        state = self.states.load(book_id)
        exported = state.steps[StepId.EXPORT]
        if exported.status is not StepStatus.DONE or exported.success is None or exported.success.revision_id != revision_id:
            raise PipelineError("EXPORT_REVISION_STALE", "资源包已经更新，请刷新后下载。", status_code=409)
        success = self._require(book_id, StepId.EXPORT, exported.success, "资源包")
        bundle = next((item.path for item in success.outputs if item.path.endswith(".readalongbook")), None)
        if not bundle:
            raise PipelineError("EXPORT_BUNDLE_NOT_FOUND", "资源包文件不存在。", status_code=404)
        root = self.paths.book(book_id) / success.output_root
        path = ensure_within(root, root / Path(*PurePosixPath(bundle).parts))
        if not path.is_file():
            raise PipelineError("EXPORT_BUNDLE_NOT_FOUND", "资源包文件不存在。", status_code=404)
        return path

    def _load_pages(self, book_id: str, status: StepStatus, success: StepSuccess | None, checks: list[ExportCheck]) -> PagePlan | None:
        if status is not StepStatus.DONE or success is None:
            checks.append(ExportCheck(id="pages", label="页面与缩略图", status="error", detail="页面处理尚未完成或已失效。"))
            return None
        try:
            checked = self._require(book_id, StepId.PAGES, success, "页面结果")
            plan = PagePlan.model_validate_json((self.paths.book(book_id) / checked.output_root / "page_plan.json").read_text(encoding="utf-8"))
            checks.append(ExportCheck(id="pages", label="页面与缩略图", status="pass", detail=f"{sum(len(item.outputs) for item in plan.pages)} 张阅读页已准备好。"))
            return plan
        except (OSError, ValueError, PipelineError):
            checks.append(ExportCheck(id="pages", label="页面与缩略图", status="error", detail="页面产物不可用，请重新处理页面。"))
            return None

    def _load_sentences(self, book_id: str, status: StepStatus, success: StepSuccess | None, checks: list[ExportCheck]) -> OcrSentences | None:
        if status is not StepStatus.DONE or success is None:
            checks.append(ExportCheck(id="sentences", label="校对句子", status="error", detail="尚未发布校对结果或结果已失效。"))
            return None
        try:
            checked = self._require(book_id, StepId.PROOFREAD, success, "校对结果")
            document = OcrSentences.model_validate_json((self.paths.book(book_id) / checked.output_root / "sentences_final.json").read_text(encoding="utf-8"))
            checks.append(ExportCheck(id="sentences", label="校对句子", status="pass", detail=f"{len(document.sentences)} 句已确认。"))
            return document
        except (OSError, ValueError, PipelineError):
            checks.append(ExportCheck(id="sentences", label="校对句子", status="error", detail="校对产物不可用，请重新校对。"))
            return None

    def _load_audio(self, book_id: str, status: StepStatus, success: StepSuccess | None, checks: list[ExportCheck]) -> AudioGenerationReport | None:
        if status is not StepStatus.DONE or success is None:
            checks.append(ExportCheck(id="audio-source", label="语音生成", status="error", detail="全书语音尚未生成或结果已失效。"))
            return None
        try:
            checked = self._require(book_id, StepId.AUDIO, success, "音频结果")
            return AudioGenerationReport.model_validate_json((self.paths.book(book_id) / checked.output_root / "tts_report.json").read_text(encoding="utf-8"))
        except (OSError, ValueError, PipelineError):
            checks.append(ExportCheck(id="audio-source", label="语音生成", status="error", detail="音频产物不可用，请重新生成语音。"))
            return None

    def _require(self, book_id: str, step: StepId, success: StepSuccess, label: str) -> StepSuccess:
        if not self._verify(book_id, step, success):
            raise PipelineError("EXPORT_INPUT_INVALID", f"{label}不完整，请重新生成。", status_code=409)
        return success

    def _verify(self, book_id: str, step: StepId, success: StepSuccess) -> bool:
        key = (book_id, success.revision_id)
        if key not in self._verified and not self.artifacts.verify(book_id, step, success):
            return False
        self._verified.add(key)
        return True
