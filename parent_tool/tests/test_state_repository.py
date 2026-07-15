from pathlib import Path

import pytest

from app.models.errors import PipelineError
from app.models.pipeline import PipelineState, StepId, StepState, StepStatus
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository


def _new_state(book_id: str = "book-1") -> PipelineState:
    return PipelineState.new(book_id=book_id, pdf_path="source.pdf", pdf_sha256="a" * 64)


def test_create_and_load_round_trip(tmp_path: Path) -> None:
    repository = StateRepository(WorkspacePaths(tmp_path))

    created = repository.create(_new_state())
    loaded = repository.load("book-1")

    assert loaded == created
    assert (tmp_path / "book-1" / "state.json").is_file()


def test_create_rejects_existing_book(tmp_path: Path) -> None:
    repository = StateRepository(WorkspacePaths(tmp_path))
    repository.create(_new_state())

    with pytest.raises(PipelineError) as caught:
        repository.create(_new_state())

    assert caught.value.code == "BOOK_ALREADY_EXISTS"


def test_load_missing_book_has_fixed_error(tmp_path: Path) -> None:
    repository = StateRepository(WorkspacePaths(tmp_path))

    with pytest.raises(PipelineError) as caught:
        repository.load("missing")

    assert caught.value.code == "BOOK_NOT_FOUND"
    assert caught.value.status_code == 404
    assert not (tmp_path / "missing").exists()


def test_update_increments_revision_once(tmp_path: Path) -> None:
    repository = StateRepository(WorkspacePaths(tmp_path))
    repository.create(_new_state())

    updated = repository.update(
        "book-1",
        lambda state: state.steps.__setitem__(
            StepId.PAGES, StepState(status=StepStatus.FAILED)
        ),
    )

    assert updated.revision == 1
    assert repository.load("book-1").steps[StepId.PAGES].status is StepStatus.FAILED


def test_corrupt_state_is_not_overwritten(tmp_path: Path) -> None:
    repository = StateRepository(WorkspacePaths(tmp_path))
    repository.create(_new_state())
    state_path = tmp_path / "book-1" / "state.json"
    state_path.write_text("{broken", encoding="utf-8")

    with pytest.raises(PipelineError) as caught:
        repository.load("book-1")

    assert caught.value.code == "WORKSPACE_STATE_CORRUPT"
    assert state_path.read_text(encoding="utf-8") == "{broken"


def test_unknown_schema_is_not_rewritten(tmp_path: Path) -> None:
    repository = StateRepository(WorkspacePaths(tmp_path))
    repository.create(_new_state())
    state_path = tmp_path / "book-1" / "state.json"
    original = state_path.read_text(encoding="utf-8").replace(
        '"schema_version":1', '"schema_version":99'
    )
    state_path.write_text(original, encoding="utf-8")

    with pytest.raises(PipelineError) as caught:
        repository.load("book-1")

    assert caught.value.code == "WORKSPACE_SCHEMA_UNSUPPORTED"
    assert state_path.read_text(encoding="utf-8") == original


def test_list_books_ignores_engine_and_non_workspaces(tmp_path: Path) -> None:
    repository = StateRepository(WorkspacePaths(tmp_path))
    repository.create(_new_state("book-1"))
    repository.create(_new_state("book-2"))
    (tmp_path / ".engine").mkdir(exist_ok=True)
    (tmp_path / "notes").mkdir()

    assert repository.list_books() == ("book-1", "book-2")
