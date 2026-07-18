from __future__ import annotations

from io import BytesIO
from pathlib import Path, PurePosixPath

import fitz
from PIL import Image

from app.models.errors import PipelineError
from app.models.ocr import OcrSentences
from app.models.page_workspace import PageWorkspaceResponse
from app.models.pages import PagePlan
from app.models.pipeline import StepId, StepStatus, StepSuccess
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.paths import WorkspacePaths, ensure_within
from app.pipeline.state_repository import StateRepository


class PageWorkspaceService:
    def __init__(
        self,
        paths: WorkspacePaths,
        states: StateRepository,
        artifacts: ArtifactStore,
    ) -> None:
        self.paths = paths
        self.states = states
        self.artifacts = artifacts
        self._verified_revisions: set[tuple[str, str]] = set()

    def load(self, book_id: str) -> PageWorkspaceResponse:
        state = self.states.load(book_id)
        success = self._pages_success(book_id, state.steps[StepId.PAGES].success)
        revision = self.paths.book(book_id) / success.output_root
        plan = self._read_plan(revision / "page_plan.json")

        ocr_revision_id: str | None = None
        sentences = ()
        ocr_state = state.steps[StepId.OCR]
        if (
            ocr_state.status is StepStatus.DONE
            and ocr_state.success is not None
            and self.artifacts.verify(book_id, StepId.OCR, ocr_state.success)
        ):
            ocr_root = self.paths.book(book_id) / ocr_state.success.output_root
            try:
                ocr = OcrSentences.model_validate_json(
                    (ocr_root / "sentences.json").read_text(encoding="utf-8")
                )
            except (OSError, ValueError) as exc:
                raise PipelineError(
                    "OCR_OUTPUT_INVALID",
                    "OCR 结果无法读取，请重新运行 OCR。",
                    status_code=409,
                ) from exc
            ocr_revision_id = ocr_state.success.revision_id
            sentences = ocr.sentences

        return PageWorkspaceResponse(
            revision_id=success.revision_id,
            plan=plan,
            ocr_revision_id=ocr_revision_id,
            sentences=sentences,
        )

    def asset(self, book_id: str, revision_id: str, asset_path: str) -> Path:
        state = self.states.load(book_id)
        success = self._pages_success(book_id, state.steps[StepId.PAGES].success)
        if revision_id != success.revision_id:
            raise PipelineError(
                "PAGE_REVISION_STALE",
                "页面结果已经更新，请刷新后继续编辑。",
                status_code=409,
            )
        normalized = PurePosixPath(asset_path).as_posix()
        allowed = {item.path for item in success.outputs if item.path != "page_plan.json"}
        if normalized not in allowed:
            raise PipelineError("PAGE_ASSET_NOT_FOUND", "页面图片不存在。", status_code=404)
        revision = self.paths.book(book_id) / success.output_root
        candidate = ensure_within(revision, revision / Path(*PurePosixPath(normalized).parts))
        if not candidate.is_file():
            raise PipelineError("PAGE_ASSET_NOT_FOUND", "页面图片不存在。", status_code=404)
        return candidate

    def render_source(self, book_id: str, source_pdf_page: int, max_edge: int) -> bytes:
        workspace = self.load(book_id)
        if source_pdf_page > workspace.plan.source_pdf_page_count:
            raise PipelineError("SOURCE_PAGE_NOT_FOUND", "源 PDF 页不存在。", status_code=404)
        source = self.paths.book(book_id) / "source.pdf"
        try:
            document = fitz.open(source)
            try:
                page = document.load_page(source_pdf_page - 1)
                pixmap = page.get_pixmap(dpi=144, alpha=False)
                image = Image.frombytes("RGB", (pixmap.width, pixmap.height), pixmap.samples)
            finally:
                document.close()
        except (OSError, RuntimeError, ValueError, fitz.FileDataError) as exc:
            raise PipelineError(
                "SOURCE_PREVIEW_FAILED",
                "源 PDF 页面预览生成失败，请重新导入资源。",
                status_code=409,
            ) from exc
        current_edge = max(image.size)
        if current_edge > max_edge:
            scale = max_edge / current_edge
            size = (max(1, round(image.width * scale)), max(1, round(image.height * scale)))
            image = image.resize(size, Image.Resampling.LANCZOS)
        output = BytesIO()
        image.save(output, format="WEBP", quality=82, method=4)
        return output.getvalue()

    def _pages_success(self, book_id: str, success: StepSuccess | None) -> StepSuccess:
        if success is None:
            raise PipelineError(
                "PAGE_PROCESSING_NOT_READY",
                "页面分析尚未完成，请先运行页面处理。",
                status_code=409,
            )
        verification_key = (book_id, success.revision_id)
        if (
            verification_key not in self._verified_revisions
            and not self.artifacts.verify(book_id, StepId.PAGES, success)
        ):
            raise PipelineError(
                "PAGE_OUTPUT_INVALID",
                "页面处理结果不完整，请重新运行页面处理。",
                status_code=409,
            )
        self._verified_revisions.add(verification_key)
        return success

    @staticmethod
    def _read_plan(path: Path) -> PagePlan:
        try:
            return PagePlan.model_validate_json(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise PipelineError(
                "PAGE_OUTPUT_INVALID",
                "页面计划无法读取，请重新运行页面处理。",
                status_code=409,
            ) from exc
