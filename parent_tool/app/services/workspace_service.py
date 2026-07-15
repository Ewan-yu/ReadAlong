from __future__ import annotations

import os
import re
import shutil
from datetime import datetime
from pathlib import Path
from uuid import uuid4

import fitz

from app.models.errors import PipelineError
from app.models.pipeline import PipelineState
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository


class WorkspaceService:
    def __init__(self, paths: WorkspacePaths, states: StateRepository) -> None:
        self.paths = paths
        self.states = states

    def create_from_pdf(self, source: Path, book_id: str) -> PipelineState:
        source = source.expanduser().resolve()
        target = self.paths.book(book_id)
        if target.exists():
            raise PipelineError(
                "BOOK_ALREADY_EXISTS",
                "同一书籍工作区已存在。",
                details={"book_id": book_id},
                status_code=409,
            )
        if source.suffix.lower() != ".pdf" or not source.is_file():
            raise PipelineError(
                "SOURCE_FILE_INVALID",
                "请选择可读取的 PDF 文件。",
                status_code=422,
            )
        try:
            self._validate_pdf(source)
        except (OSError, fitz.FileDataError, fitz.EmptyFileError, RuntimeError) as exc:
            raise PipelineError(
                "SOURCE_FILE_INVALID",
                "PDF 文件无法打开或内容无效。",
                status_code=422,
            ) from exc
        target.mkdir(parents=True)
        temporary = target / f".source-{uuid4().hex}.tmp"
        copied = target / "source.pdf"
        try:
            with source.open("rb") as input_stream, temporary.open("wb") as output_stream:
                shutil.copyfileobj(input_stream, output_stream, length=1024 * 1024)
                output_stream.flush()
                os.fsync(output_stream.fileno())
            os.replace(temporary, copied)
            state = PipelineState.new(
                book_id=book_id,
                pdf_path="source.pdf",
                pdf_sha256=file_sha256(copied),
            )
            return self.states.create(state)
        except PipelineError:
            raise
        except (OSError, fitz.FileDataError, fitz.EmptyFileError, RuntimeError) as exc:
            raise PipelineError(
                "SOURCE_FILE_INVALID",
                "PDF 文件无法打开或内容无效。",
                status_code=422,
            ) from exc
        finally:
            temporary.unlink(missing_ok=True)
            if not (target / "state.json").is_file():
                shutil.rmtree(target, ignore_errors=True)

    def next_book_id(self, filename: str, *, now: datetime | None = None) -> str:
        stem = Path(filename).stem.lower()
        slug = re.sub(r"[^a-z0-9]+", "-", stem).strip("-") or "book"
        date = (now or datetime.now()).strftime("%Y%m%d")
        suffix_length = len(date) + 4
        slug = slug[: 96 - suffix_length].rstrip("-") or "book"
        for sequence in range(1, 1000):
            book_id = f"{slug}-{date}-{sequence:02d}"
            if not self.paths.book(book_id).exists():
                return book_id
        raise PipelineError(
            "BOOK_ID_EXHAUSTED",
            "当天同名书籍数量过多，无法创建工作区。",
            status_code=409,
        )

    @staticmethod
    def _validate_pdf(path: Path) -> None:
        document = fitz.open(path, filetype="pdf")
        try:
            if document.page_count < 1:
                raise PipelineError(
                    "SOURCE_FILE_INVALID",
                    "PDF 不包含可处理页面。",
                    status_code=422,
                )
        finally:
            document.close()
