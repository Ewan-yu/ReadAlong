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
from app.pipeline.original_timeline import (
    TIMELINE_PATH,
    load_and_validate_timeline,
    timeline_manifest_entry,
    validate_timeline_against_alignment_db,
)
from app.pipeline.paths import ensure_within
from app.providers.media import FfprobeMediaProbe
from app.providers.tts.ffmpeg import FfmpegOpusTranscoder


class ExportStep:
    step_id = StepId.EXPORT
    implementation_version = "export-v2"
    params_model = ExportParams

    def __init__(
        self,
        media_probe: FfprobeMediaProbe | None = None,
        playback_transcoder: FfmpegOpusTranscoder | None = None,
    ) -> None:
        self._media_probe = media_probe or FfprobeMediaProbe()
        self._playback_transcoder = playback_transcoder or FfmpegOpusTranscoder()

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
            original_audio = self._copy_original_audio(assembly, context)
            self._create_original_playback(assembly, context, original_audio)
            manifest = self._manifest(context.book_id, title, plan, original_audio)
            self._copy_confirmed_background(assembly, context, original_audio)
            self._copy_pages(assembly, pages_root, outputs)
            self._copy_audio(assembly, audio_root, by_audio)
            alignment_path = assembly / "align" / "alignment.db"
            self._write_alignment(alignment_path, context.book_id, title, manifest, sentences, by_audio)
            self._copy_original_timeline(
                assembly,
                context,
                original_audio,
                sentences,
                alignment_path,
            )
            self._validate_manifest(manifest)
            (assembly / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
            self._zip(assembly, bundle)
        report = {
            "book_id": context.book_id,
            "pages": len(outputs),
            "sentences": len(sentences.sentences),
            "word_timing_sentences": sum(
                item.word_timing is not None for item in audio.sentences
            ),
            "size_bytes": bundle.stat().st_size,
            "sha256": file_sha256(bundle),
            "original_audio": original_audio,
        }
        (context.staging_dir / "validation_report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        context.progress(1, "资源包导出完成。")
        return StepResult(outputs=(bundle_name, "validation_report.json"), summary=report)

    @staticmethod
    def _manifest(
        book_id: str,
        title: str,
        plan: PagePlan,
        original_audio: dict | None = None,
    ) -> dict:
        outputs = [(entry, item) for entry in plan.pages for item in entry.outputs]
        manifest = {"schema_version": 1, "book_id": book_id, "title": title, "language": "en", "created_at": utc_now().isoformat(), "generator": {"name": "ReadAlong Parent Tool", "version": "0.1.0"}, "page_count": len(outputs), "page_image": {"format": "webp", "max_long_edge_px": plan.params.reading_long_edge, "quality": plan.params.webp_quality}, "thumbnail": {"format": "jpg", "max_long_edge_px": plan.params.thumbnail_long_edge, "quality": plan.params.thumbnail_quality}, "pages": [{"page_no": item.page_no, "image": item.page_image, "thumbnail": item.thumbnail, "width_px": item.width, "height_px": item.height, "source_pdf_page": entry.source_pdf_page, "source_region": item.region.value} for entry, item in outputs]}
        if original_audio is not None:
            manifest["original_audio"] = original_audio
        return manifest

    def _copy_original_audio(
        self,
        assembly: Path,
        context: StepRunContext,
    ) -> dict | None:
        declared_path = context.source_original_audio_path
        declared_sha256 = context.source_original_audio_sha256
        if declared_path is None and declared_sha256 is None:
            return None
        if not declared_path or not declared_sha256:
            raise PipelineError(
                "ORIGINAL_AUDIO_STATE_INVALID",
                "工作区原音信息不完整，请重新创建绘本工作区。",
                status_code=409,
            )
        source = ensure_within(context.workspace_dir, context.workspace_dir / Path(declared_path))
        if not source.is_file():
            raise PipelineError(
                "ORIGINAL_AUDIO_MISSING",
                "工作区中的原音音频不存在，无法导出。",
                details={"path": declared_path},
                status_code=409,
            )
        size_bytes = source.stat().st_size
        if size_bytes <= 0:
            raise PipelineError(
                "ORIGINAL_AUDIO_INVALID",
                "工作区中的原音音频为空，无法导出。",
                status_code=409,
            )
        actual_sha256 = file_sha256(source)
        if actual_sha256 != declared_sha256:
            raise PipelineError(
                "ORIGINAL_AUDIO_HASH_MISMATCH",
                "原音音频已被修改，请重新导入后再导出。",
                details={"expected": declared_sha256, "actual": actual_sha256},
                status_code=409,
            )
        target = assembly / "original" / "source.mp3"
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            shutil.copyfile(source, target)
        except OSError as exc:
            raise PipelineError(
                "ORIGINAL_AUDIO_COPY_FAILED",
                "原音音频无法写入资源包。",
                status_code=500,
            ) from exc
        packaged_size = target.stat().st_size
        packaged_sha256 = file_sha256(target)
        if packaged_size != size_bytes or packaged_sha256 != declared_sha256:
            raise PipelineError(
                "ORIGINAL_AUDIO_HASH_MISMATCH",
                "原音音频在导出期间发生变化，请重试。",
                details={"expected": declared_sha256, "actual": packaged_sha256},
                status_code=409,
            )
        duration_ms = self._media_probe.duration_ms(target, context.cancellation)
        return {
            "path": "original/source.mp3",
            "mime_type": "audio/mpeg",
            "size_bytes": packaged_size,
            "sha256": packaged_sha256,
            "duration_ms": duration_ms,
            "alignment_status": "raw",
        }

    def _create_original_playback(
        self,
        assembly: Path,
        context: StepRunContext,
        original_audio: dict | None,
    ) -> None:
        """Create a local, broadly supported original-audio playback asset.

        The MP3 remains the immutable parent-uploaded source and the timeline
        identity anchor.  This Opus copy exists only for playback, preventing
        device-specific MP3 decoder failures from blocking the child reader.
        """
        if original_audio is None:
            return
        source = assembly / "original" / "source.mp3"
        target = assembly / "original" / "playback.ogg"
        self._playback_transcoder.transcode_original_playback(
            source,
            target,
            cancellation=context.cancellation,
        )
        if not target.is_file() or target.stat().st_size <= 0:
            raise PipelineError(
                "ORIGINAL_AUDIO_TRANSCODE_FAILED",
                "无法生成设备兼容的原音播放音频。",
                status_code=500,
            )
        original_audio["playback"] = {
            "path": "original/playback.ogg",
            "mime_type": "audio/ogg",
            "size_bytes": target.stat().st_size,
            "sha256": file_sha256(target),
        }

    @staticmethod
    def _copy_confirmed_background(
        assembly: Path,
        context: StepRunContext,
        original_audio: dict | None,
    ) -> None:
        if (
            original_audio is None
            or context.confirmed_original_audio_output is None
            or not context.include_original_background
        ):
            return
        root = context.confirmed_original_audio_output
        try:
            report = json.loads((root / "separation_report.json").read_text(encoding="utf-8"))
            background = report["background"]
            source_hash = report["source_sha256"]
            source = root / background["path"]
            if (
                source_hash != original_audio["sha256"]
                or background["path"] != "background.ogg"
                or not source.is_file()
                or file_sha256(source) != background["sha256"]
                or int(background["duration_ms"]) <= 0
            ):
                raise ValueError
        except (OSError, KeyError, TypeError, ValueError) as exc:
            raise PipelineError(
                "ORIGINAL_AUDIO_BACKGROUND_INVALID",
                "已确认的原音背景轨已损坏，请重新分离或选择纯人声。",
                status_code=409,
            ) from exc
        target = assembly / "original" / "background.ogg"
        shutil.copyfile(source, target)
        digest = file_sha256(target)
        if digest != background["sha256"]:
            raise PipelineError("ORIGINAL_AUDIO_BACKGROUND_INVALID", "背景轨复制校验失败。", status_code=409)
        original_audio["background"] = {
            "path": "original/background.ogg",
            "mime_type": "audio/ogg",
            "size_bytes": target.stat().st_size,
            "sha256": digest,
            "duration_ms": int(background["duration_ms"]),
            "method": "source_separation",
        }

    @staticmethod
    def _copy_original_timeline(
        assembly: Path,
        context: StepRunContext,
        original_audio: dict | None,
        sentences: OcrSentences,
        alignment_path: Path,
    ) -> None:
        """Publish original playback only when every identity/hash gate passes.

        A stale or failed timeline is deliberately omitted: raw original audio
        remains exportable, but the reader must not advertise word highlighting.
        """

        root = context.original_timeline_output
        if original_audio is None or root is None:
            return
        confirmed = context.confirmed_original_audio_output
        if confirmed is None:
            return
        try:
            separation = json.loads((confirmed / "separation_report.json").read_text(encoding="utf-8"))
            vocal_sha256 = str(separation["vocals_preview"]["sha256"])
            source_sha256 = str(separation["source_sha256"])
            source = root / TIMELINE_PATH
            if source_sha256 != original_audio["sha256"] or not source.is_file():
                raise ValueError
            timeline = load_and_validate_timeline(
                source,
                sentences=sentences,
                proofread_revision=context.dependency_outputs[StepId.PROOFREAD].name,
                original_audio_revision=confirmed.name,
                original_audio_sha256=original_audio["sha256"],
                vocal_sha256=vocal_sha256,
                duration_ms=int(original_audio["duration_ms"]),
            )
            validate_timeline_against_alignment_db(timeline, alignment_path)
        except (OSError, ValueError, TypeError, json.JSONDecodeError, PipelineError) as exc:
            raise PipelineError(
                "ORIGINAL_TIMELINE_EXPORT_INVALID",
                "原音逐词时间线未通过校验，请重新生成后再导出。",
                status_code=409,
            ) from exc
        target = assembly / TIMELINE_PATH
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if file_sha256(target) != file_sha256(source):
            raise PipelineError("ORIGINAL_TIMELINE_EXPORT_INVALID", "原音逐词时间线复制校验失败。", status_code=409)
        original_audio["alignment_status"] = "ready"
        original_audio.update(timeline_manifest_entry(target, timeline))

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
