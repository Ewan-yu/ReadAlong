from __future__ import annotations

from pathlib import Path

import cv2
import fitz
import numpy as np
from PIL import Image

from app.models.errors import PipelineError
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
from app.models.pipeline import StepId, StepResult
from app.pipeline.definitions import StepRunContext
from app.pipeline.hashing import file_sha256


class PageProcessingStep:
    step_id = StepId.PAGES
    implementation_version = "pages-v1"
    params_model = PageProcessParams

    def run(self, context: StepRunContext, params: PageProcessParams) -> StepResult:
        source = context.workspace_dir / "source.pdf"
        self._validate_source(source, context.source_pdf_sha256)
        try:
            document = fitz.open(source)
        except (OSError, fitz.FileDataError, fitz.EmptyFileError, RuntimeError) as exc:
            raise PipelineError("SOURCE_FILE_INVALID", "PDF 文件无法打开或内容无效。", status_code=422) from exc

        try:
            if document.page_count < 1:
                raise PipelineError("SOURCE_FILE_INVALID", "PDF 不包含可处理页面。", status_code=422)
            entries, output_paths = self._render_document(document, context, params)
            plan = PagePlan(
                source_pdf_sha256=context.source_pdf_sha256 or file_sha256(source),
                source_pdf_page_count=document.page_count,
                params=params,
                pages=tuple(entries),
            )
            plan_path = context.staging_dir / "page_plan.json"
            plan_path.write_text(plan.model_dump_json(indent=2), encoding="utf-8")
            context.progress(1, "页面处理完成。")
            return StepResult(outputs=("page_plan.json", *output_paths))
        except PipelineError:
            raise
        except (OSError, ValueError, fitz.FileDataError, fitz.EmptyFileError, RuntimeError) as exc:
            raise PipelineError(
                "PAGE_PROCESSING_FAILED",
                "页面渲染或图片导出失败。",
                status_code=500,
            ) from exc
        finally:
            document.close()

    def _render_document(
        self,
        document: fitz.Document,
        context: StepRunContext,
        params: PageProcessParams,
    ) -> tuple[list[PagePlanEntry], tuple[str, ...]]:
        entries: list[PagePlanEntry] = []
        paths: list[str] = []
        final_page_no = 1
        total_units = max(document.page_count * 7, 1)
        completed_units = 0

        for source_index, pdf_page in enumerate(document, start=1):
            context.cancellation.raise_if_cancelled()
            detection_image = self._render_page(pdf_page, params.detection_dpi)
            detect = self._detect_split(detection_image, params)
            decision = self._default_decision(detect, params)
            ocr_image = self._render_page(pdf_page, params.ocr_dpi)
            completed_units += 1
            context.progress(completed_units / total_units, f"正在渲染源页 {source_index}/{document.page_count}。")

            regions = (PageRegion.FULL,) if decision.mode is PageMode.KEEP else (
                PageRegion.LEFT,
                PageRegion.RIGHT,
            )
            outputs: list[PageOutput] = []
            for region in regions:
                context.cancellation.raise_if_cancelled()
                transformed_ocr = self._apply_decision(ocr_image, decision, region)
                transformed_reading = self._resize_long_edge(transformed_ocr, params.reading_long_edge)
                page_no = final_page_no
                final_page_no += 1
                ocr_relative = f"ocr/p{page_no:04d}.png"
                page_relative = f"pages/p{page_no:04d}.webp"
                thumbnail_relative = f"thumbnails/p{page_no:04d}.jpg"
                self._save_image(context.staging_dir / ocr_relative, transformed_ocr, "PNG")
                self._save_image(
                    context.staging_dir / page_relative,
                    transformed_reading,
                    "WEBP",
                    quality=params.webp_quality,
                )
                thumbnail = self._resize_long_edge(transformed_reading, params.thumbnail_long_edge)
                self._save_image(
                    context.staging_dir / thumbnail_relative,
                    thumbnail,
                    "JPEG",
                    quality=params.thumbnail_quality,
                )
                paths.extend((ocr_relative, page_relative, thumbnail_relative))
                outputs.append(
                    PageOutput(
                        page_no=page_no,
                        region=region,
                        ocr_image=ocr_relative,
                        page_image=page_relative,
                        thumbnail=thumbnail_relative,
                        width=transformed_reading.width,
                        height=transformed_reading.height,
                    )
                )
                completed_units += 3
                context.progress(
                    min(completed_units / total_units, 0.99),
                    f"正在导出阅读页 {page_no}。",
                )
            entries.append(
                PagePlanEntry(
                    source_pdf_page=source_index,
                    source_size_pt=SourcePageSize(width=pdf_page.rect.width, height=pdf_page.rect.height),
                    detect=detect,
                    decision=decision,
                    outputs=tuple(outputs),
                )
            )
        return entries, tuple(paths)

    @staticmethod
    def _validate_source(source: Path, expected_sha256: str | None) -> None:
        if not source.is_file():
            raise PipelineError("SOURCE_FILE_MISSING", "工作区中的 source.pdf 不存在。", status_code=409)
        if expected_sha256 is not None and file_sha256(source) != expected_sha256:
            raise PipelineError(
                "SOURCE_FILE_CHANGED",
                "源 PDF 已被修改，请重新导入资源。",
                status_code=409,
            )

    @staticmethod
    def _render_page(page: fitz.Page, dpi: int) -> Image.Image:
        pixmap = page.get_pixmap(dpi=dpi, alpha=False)
        return Image.frombytes("RGB", (pixmap.width, pixmap.height), pixmap.samples)

    @staticmethod
    def _default_decision(detect: PageDetect, params: PageProcessParams) -> PageDecision:
        if not detect.suspect_split:
            return PageDecision(mode=PageMode.KEEP, confirmed=True)
        return PageDecision(
            mode=PageMode.SPLIT_LR,
            split_ratio=detect.suggested_split_ratio,
            confirmed=detect.confidence >= params.confirmation_confidence,
        )

    @staticmethod
    def _detect_split(image: Image.Image, params: PageProcessParams) -> PageDetect:
        width, height = image.size
        if not params.split_detection_enabled or width / height <= params.wide_ratio_threshold:
            return PageDetect(suspect_split=False, confidence=0)
        grayscale = np.asarray(image.convert("L"))
        start = max(0, int(width * params.center_window_start))
        end = min(width, int(width * params.center_window_end))
        if end <= start:
            return PageDetect(suspect_split=True, confidence=0, suggested_split_ratio=0.5)
        window = grayscale[:, start:end]
        ink_density = np.mean(window < 220, axis=0).astype(np.float32)
        edges = cv2.Canny(window, 80, 180)
        edge_density = np.mean(edges > 0, axis=0).astype(np.float32)
        content = ink_density * 0.6 + edge_density * 0.4
        minimum = float(content.min())
        median = float(np.median(content))
        candidate_indexes = np.flatnonzero(np.isclose(content, minimum))
        midpoint = (len(content) - 1) / 2
        best = int(candidate_indexes[np.argmin(np.abs(candidate_indexes - midpoint))])
        confidence = 0 if median <= 1e-6 else round(max(0, min(1, (median - minimum) / median)) * 100)
        ratio = (start + best + 0.5) / width
        return PageDetect(
            suspect_split=True,
            confidence=confidence,
            suggested_split_ratio=round(ratio, 6),
        )

    @staticmethod
    def _apply_decision(image: Image.Image, decision: PageDecision, region: PageRegion) -> Image.Image:
        result = image
        if decision.mode is PageMode.SPLIT_LR:
            assert decision.split_ratio is not None
            split = round(result.width * decision.split_ratio)
            if region is PageRegion.LEFT:
                result = result.crop((0, 0, split, result.height))
            else:
                result = result.crop((split, 0, result.width, result.height))
        if decision.rotate == 90:
            result = result.transpose(Image.Transpose.ROTATE_270)
        elif decision.rotate == 180:
            result = result.transpose(Image.Transpose.ROTATE_180)
        elif decision.rotate == 270:
            result = result.transpose(Image.Transpose.ROTATE_90)
        crop = decision.crop_pct
        left = round(result.width * crop.left / 100)
        right = result.width - round(result.width * crop.right / 100)
        top = round(result.height * crop.top / 100)
        bottom = result.height - round(result.height * crop.bottom / 100)
        return result.crop((left, top, right, bottom))

    @staticmethod
    def _resize_long_edge(image: Image.Image, target: int) -> Image.Image:
        current = max(image.size)
        if current <= target:
            return image
        scale = target / current
        size = (max(1, round(image.width * scale)), max(1, round(image.height * scale)))
        return image.resize(size, Image.Resampling.LANCZOS)

    @staticmethod
    def _save_image(path: Path, image: Image.Image, image_format: str, **options: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        if image_format == "JPEG" and image.mode != "RGB":
            image = image.convert("RGB")
        image.save(path, format=image_format, **options)
