from __future__ import annotations

import json
import shutil
import sqlite3
import tempfile
import zipfile
from pathlib import Path

import jsonschema

from app.models.audio import AudioGenerationReport
from app.models.errors import PipelineError
from app.models.export import ExportParams
from app.models.ocr import OcrSentences
from app.models.pages import PagePlan
from app.models.pipeline import StepId, StepResult, utc_now
from app.pipeline.definitions import StepRunContext
from app.pipeline.hashing import file_sha256


class ExportStep:
    step_id = StepId.EXPORT
    implementation_version = "export-v1"
    params_model = ExportParams

    def run(self, context: StepRunContext, params: ExportParams) -> StepResult:
        try:
            pages_root = context.dependency_outputs[StepId.PAGES]
            proofread_root = context.dependency_outputs[StepId.PROOFREAD]
            audio_root = context.dependency_outputs[StepId.AUDIO]
            plan = PagePlan.model_validate_json((pages_root / "page_plan.json").read_text(encoding="utf-8"))
            sentences = OcrSentences.model_validate_json(
                (proofread_root / "sentences_final.json").read_text(encoding="utf-8")
            )
            audio = AudioGenerationReport.model_validate_json(
                (audio_root / "tts_report.json").read_text(encoding="utf-8")
            )
        except (KeyError, OSError, ValueError) as exc:
            raise PipelineError("EXPORT_INPUT_INVALID", "导出所需的上游产物不存在或已损坏。", status_code=409) from exc
        outputs = tuple(item for entry in plan.pages for item in entry.outputs)
        by_audio = {item.sentence_id: item for item in audio.sentences}
        missing = [item.id for item in sentences.sentences if item.id not in by_audio or not by_audio[item.id].audio_path]
        if missing:
            raise PipelineError("EXPORT_AUDIO_MISSING", "存在未生成音频的句子，不能导出。", details={"sentence_ids": missing}, status_code=409)
        title = params.title or context.book_id.replace("-", " ").title()
        bundle_name = f"{context.book_id}.readalongbook"
        bundle = context.staging_dir / bundle_name
        with tempfile.TemporaryDirectory(prefix=".export-", dir=context.staging_dir) as temporary:
            assembly = Path(temporary)
            manifest = self._manifest(context.book_id, title, plan)
            self._validate_manifest(manifest)
            (assembly / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
            self._copy_pages(assembly, pages_root, outputs)
            self._copy_audio(assembly, audio_root, by_audio)
            self._write_alignment(assembly / "align" / "alignment.db", context.book_id, title, manifest, sentences, by_audio)
            self._zip(assembly, bundle)
        report = {"book_id": context.book_id, "pages": len(outputs), "sentences": len(sentences.sentences), "word_timing_sentences": sum(item.word_timing is not None for item in audio.sentences), "size_bytes": bundle.stat().st_size, "sha256": file_sha256(bundle)}
        (context.staging_dir / "validation_report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        context.progress(1, "资源包导出完成。")
        return StepResult(outputs=(bundle_name, "validation_report.json"), summary=report)

    @staticmethod
    def _manifest(book_id: str, title: str, plan: PagePlan) -> dict:
        outputs = [(entry, item) for entry in plan.pages for item in entry.outputs]
        return {"schema_version": 1, "book_id": book_id, "title": title, "language": "en", "created_at": utc_now().isoformat(), "generator": {"name": "ReadAlong Parent Tool", "version": "0.1.0"}, "page_count": len(outputs), "page_image": {"format": "webp", "max_long_edge_px": plan.params.reading_long_edge, "quality": plan.params.webp_quality}, "thumbnail": {"format": "jpg", "max_long_edge_px": plan.params.thumbnail_long_edge, "quality": plan.params.thumbnail_quality}, "pages": [{"page_no": item.page_no, "image": item.page_image, "thumbnail": item.thumbnail, "width_px": item.width, "height_px": item.height, "source_pdf_page": entry.source_pdf_page, "source_region": item.region.value} for entry, item in outputs]}

    @staticmethod
    def _validate_manifest(manifest: dict) -> None:
        schema_path = Path(__file__).parents[4] / "shared" / "schema" / "manifest.schema.json"
        try:
            jsonschema.validate(manifest, json.loads(schema_path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError, jsonschema.ValidationError) as exc:
            raise PipelineError("EXPORT_MANIFEST_INVALID", "生成的 manifest 不符合资源包契约。", status_code=500) from exc

    @staticmethod
    def _copy_pages(assembly: Path, root: Path, outputs: tuple) -> None:
        for item in outputs:
            for relative in (item.page_image, item.thumbnail):
                source, target = root / relative, assembly / relative
                if not source.is_file():
                    raise PipelineError("EXPORT_PAGE_MISSING", "页面图片或缩略图不存在。", details={"path": relative}, status_code=409)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)

    @staticmethod
    def _copy_audio(assembly: Path, root: Path, reports: dict) -> None:
        for report in reports.values():
            assert report.audio_path
            source = root / report.audio_path
            target = assembly / "tts" / Path(report.audio_path).name
            if not source.is_file():
                raise PipelineError("EXPORT_AUDIO_MISSING", "音频文件不存在。", details={"path": report.audio_path}, status_code=409)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)

    @staticmethod
    def _write_alignment(path: Path, book_id: str, title: str, manifest: dict, sentences: OcrSentences, reports: dict) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        schema_path = Path(__file__).parents[4] / "shared" / "schema" / "alignment.sql"
        connection = sqlite3.connect(path)
        try:
            connection.executescript(schema_path.read_text(encoding="utf-8"))
            connection.execute("INSERT INTO book VALUES (?, ?, ?, ?, ?)", (book_id, title, "en", 1, manifest["created_at"]))
            for page in manifest["pages"]:
                connection.execute("INSERT INTO page (book_id,page_no,image_path,thumbnail_path,width_px,height_px,source_pdf_page,source_region) VALUES (?,?,?,?,?,?,?,?)", (book_id, page["page_no"], page["image"], page["thumbnail"], page["width_px"], page["height_px"], page["source_pdf_page"], page["source_region"]))
            for item in sentences.sentences:
                report = reports[item.id]
                assert report.audio_path and report.duration_seconds
                connection.execute("INSERT INTO sentence VALUES (?,?,?,?,?,?,?,?,?,?,?)", (item.id, book_id, item.page_no, item.seq, item.text, json.dumps({"x": item.bbox.x, "y": item.bbox.y, "w": item.bbox.width, "h": item.bbox.height}), int(item.shared_bbox), f"tts/{Path(report.audio_path).name}", 0, report.duration_seconds, "tts"))
                for index, word in enumerate(report.word_timing or (), start=1):
                    connection.execute("INSERT INTO word_timing VALUES (?,?,?,?,?,?)", (f"{item.id}-w{index:04d}", item.id, index, word.word, word.t_start, word.t_end))
            connection.commit()
        finally:
            connection.close()

    @staticmethod
    def _zip(source: Path, bundle: Path) -> None:
        with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for item in sorted(source.rglob("*")):
                if item.is_file():
                    archive.write(item, item.relative_to(source).as_posix())
