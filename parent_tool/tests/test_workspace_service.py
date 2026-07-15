from datetime import datetime
from pathlib import Path

import fitz
import pytest

from app.models.errors import PipelineError
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.services.workspace_service import WorkspaceService


def _pdf(path: Path, *, pages: int = 1) -> Path:
    document = fitz.open()
    try:
        for _ in range(pages):
            page = document.new_page(width=300, height=400)
            page.insert_text((40, 50), "ReadAlong")
        document.save(path)
    finally:
        document.close()
    return path


def test_workspace_import_copies_pdf_and_creates_state(tmp_path: Path) -> None:
    source = _pdf(tmp_path / "source.pdf")
    paths = WorkspacePaths(tmp_path / "workspace")
    repository = StateRepository(paths)
    service = WorkspaceService(paths, repository)

    state = service.create_from_pdf(source, "book-1")

    copied = paths.book("book-1") / "source.pdf"
    assert state.source.pdf_path == "source.pdf"
    assert copied.is_file()
    assert state.source.pdf_sha256 == file_sha256(source)
    assert repository.load("book-1").source.pdf_sha256 == file_sha256(copied)


def test_workspace_import_rejects_bad_extension_without_target(tmp_path: Path) -> None:
    source = tmp_path / "source.txt"
    source.write_text("not a pdf", encoding="utf-8")
    paths = WorkspacePaths(tmp_path / "workspace")
    service = WorkspaceService(paths, StateRepository(paths))

    with pytest.raises(PipelineError) as caught:
        service.create_from_pdf(source, "book-1")

    assert caught.value.code == "SOURCE_FILE_INVALID"
    assert not paths.book("book-1").exists()


def test_workspace_import_removes_half_created_target_on_invalid_pdf(tmp_path: Path) -> None:
    source = tmp_path / "bad.pdf"
    source.write_bytes(b"not a real pdf")
    paths = WorkspacePaths(tmp_path / "workspace")
    service = WorkspaceService(paths, StateRepository(paths))

    with pytest.raises(PipelineError) as caught:
        service.create_from_pdf(source, "book-1")

    assert caught.value.code == "SOURCE_FILE_INVALID"
    assert not paths.book("book-1").exists()


def test_workspace_generates_incrementing_slugged_book_ids(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "workspace")
    service = WorkspaceService(paths, StateRepository(paths))

    first = service.next_book_id("My Granny!.pdf", now=datetime(2026, 7, 15))
    paths.book(first).mkdir(parents=True)
    second = service.next_book_id("My Granny!.pdf", now=datetime(2026, 7, 15))

    assert first == "my-granny-20260715-01"
    assert second == "my-granny-20260715-02"
