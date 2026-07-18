from __future__ import annotations

from app.models.errors import PipelineError
from app.models.ocr import OcrSentences
from app.models.pages import PagePlan
from app.models.pipeline import StepId, StepStatus
from app.models.proofread_workspace import ProofreadPage, ProofreadWorkspaceResponse
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository


class ProofreadWorkspaceService:
    """Reads immutable OCR/proofread revisions into the editor's single snapshot."""

    def __init__(self, paths: WorkspacePaths, states: StateRepository, artifacts: ArtifactStore) -> None:
        self.paths = paths
        self.states = states
        self.artifacts = artifacts

    def load(self, book_id: str) -> ProofreadWorkspaceResponse:
        state = self.states.load(book_id)
        pages_success = state.steps[StepId.PAGES].success
        ocr_success = state.steps[StepId.OCR].success
        if state.steps[StepId.PAGES].status is not StepStatus.DONE or pages_success is None:
            raise PipelineError("PAGES_NOT_READY", "请先完成页面处理。", status_code=409)
        if state.steps[StepId.OCR].status is not StepStatus.DONE or ocr_success is None:
            raise PipelineError("OCR_NOT_READY", "请先完成 OCR 与句子切分。", status_code=409)
        if not self.artifacts.verify(book_id, StepId.PAGES, pages_success) or not self.artifacts.verify(book_id, StepId.OCR, ocr_success):
            raise PipelineError("OCR_ARTIFACT_INVALID", "OCR 或页面产物已损坏，请重新处理。", status_code=409)

        pages_root = self.paths.book(book_id) / pages_success.output_root
        ocr_root = self.paths.book(book_id) / ocr_success.output_root
        try:
            plan = PagePlan.model_validate_json((pages_root / "page_plan.json").read_text(encoding="utf-8"))
            draft = OcrSentences.model_validate_json((ocr_root / "sentences.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise PipelineError("OCR_ARTIFACT_INVALID", "OCR 句子初稿已损坏，请重新执行 OCR。", status_code=409) from exc

        final = draft
        proofread_revision_id: str | None = None
        proofread = state.steps[StepId.PROOFREAD]
        if proofread.status is StepStatus.DONE and proofread.success is not None and self.artifacts.verify(book_id, StepId.PROOFREAD, proofread.success):
            try:
                final = OcrSentences.model_validate_json(
                    (self.paths.book(book_id) / proofread.success.output_root / "sentences_final.json").read_text(encoding="utf-8")
                )
                proofread_revision_id = proofread.success.revision_id
            except (OSError, ValueError) as exc:
                raise PipelineError("PROOFREAD_ARTIFACT_INVALID", "已发布的校对结果损坏，请重新校对。", status_code=409) from exc

        output_by_no = {output.page_no: output for entry in plan.pages for output in entry.outputs}
        pages = tuple(
            ProofreadPage(page_no=page.page_no, image=output_by_no[page.page_no].page_image, thumbnail=output_by_no[page.page_no].thumbnail)
            for page in draft.pages
        )
        return ProofreadWorkspaceResponse(
            pages_revision_id=pages_success.revision_id,
            ocr_revision_id=ocr_success.revision_id,
            proofread_revision_id=proofread_revision_id,
            pages=pages,
            sentences=final.sentences,
            confirmed_pages=final.confirmed_pages,
        )
