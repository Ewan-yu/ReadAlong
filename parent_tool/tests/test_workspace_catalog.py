from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, cast

import fitz

from app.jobs.manager import JobManager
from app.config import Settings, UserSettingsStore
from app.models.pipeline import OutputFile, StepId, StepState, StepStatus, StepSuccess
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.services.workspace_catalog_service import WorkspaceCatalogService
from app.services.workspace_service import WorkspaceService
from app.services.workspace_migration_service import WorkspaceMigrationService


class IdleJobs:
    @contextmanager
    def maintenance(self, _operation: str = "管理工作区") -> Iterator[None]:
        yield


def _pdf(path: Path) -> Path:
    document = fitz.open()
    try:
        document.new_page(width=300, height=400)
        document.save(path)
    finally:
        document.close()
    return path


def _catalog(paths: WorkspacePaths, states: StateRepository) -> WorkspaceCatalogService:
    return WorkspaceCatalogService(
        paths, states, cast(JobManager, IdleJobs()), Settings(workspace_root=paths.root)
    )


def test_catalog_lists_metadata_size_and_continue_path(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "workspace")
    states = StateRepository(paths)
    workspace = WorkspaceService(paths, states)
    source = _pdf(tmp_path / "My Family.pdf")
    workspace.create_from_pdf(source, "my-family-1", source_filename="My Family.pdf")
    catalog = _catalog(paths, states)

    initial = catalog.list().workspaces[0]
    assert initial.display_name == "My Family"
    assert initial.source_filename == "My Family.pdf"
    assert initial.current_step is StepId.PAGES
    assert initial.continue_path == "/books/my-family-1/pages"
    assert initial.size_bytes >= source.stat().st_size

    states.update(
        "my-family-1",
        lambda state: state.steps.__setitem__(
            StepId.PAGES,
            StepState(
                status=StepStatus.DONE,
                success=StepSuccess(
                    revision_id="r-12345678",
                    output_root="01_pages/revisions/r-12345678",
                    params_hash="a" * 64,
                    input_fingerprint="b" * 64,
                    output_fingerprint="c" * 64,
                    outputs=(OutputFile(path="page_plan.json", size=0, sha256="d" * 64),),
                    completed_at=datetime.now(timezone.utc),
                ),
            ),
        ),
    )

    continued = catalog.summary("my-family-1")
    assert continued.current_step is StepId.PROOFREAD
    assert continued.continue_path == "/books/my-family-1/proofread"


def test_catalog_isolates_corrupt_workspace(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "workspace")
    book = paths.book("broken-book")
    book.mkdir(parents=True)
    (book / "state.json").write_text("not-json", encoding="utf-8")

    summary = _catalog(paths, StateRepository(paths)).list().workspaces[0]

    assert summary.book_id == "broken-book"
    assert summary.lifecycle_status.value == "corrupt"
    assert summary.error is not None
    assert summary.error.code == "WORKSPACE_STATE_CORRUPT"


def test_catalog_moves_workspace_to_trash_before_purge(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "workspace")
    states = StateRepository(paths)
    source = _pdf(tmp_path / "Delete Me.pdf")
    WorkspaceService(paths, states).create_from_pdf(source, "delete-me")
    catalog = _catalog(paths, states)

    trash = catalog.move_to_trash("delete-me")

    assert not paths.book("delete-me").exists()
    assert trash.is_dir()
    catalog.purge_trash(trash)
    assert not trash.exists()


def test_migration_converts_legacy_layout_and_keeps_source_until_restart(tmp_path: Path) -> None:
    source_root = tmp_path / "legacy-workspace"
    paths = WorkspacePaths(source_root)
    states = StateRepository(paths)
    source = _pdf(tmp_path / "Move Me.pdf")
    WorkspaceService(paths, states).create_from_pdf(source, "move-me", source_filename="Move Me.pdf")
    (paths.engine / "jobs").mkdir(parents=True)
    (paths.engine / "jobs" / "old.json").write_text("{}", encoding="utf-8")
    settings_path = tmp_path / "app-settings" / "settings.json"
    settings = Settings(
        workspace_root=source_root,
        managed_by="user",
        settings_path=settings_path,
        allow_pending_cleanup=True,
    )
    service = WorkspaceMigrationService(
        paths, cast(JobManager, IdleJobs()), settings, UserSettingsStore(settings_path)
    )

    started = service.start(str(tmp_path / "other-drive" / "ReadAlongData"))
    deadline = __import__("time").monotonic() + 5
    while __import__("time").monotonic() < deadline:
        result = service.get(started.migration_id)
        if result.phase.value in {"switched", "failed"}:
            break
        __import__("time").sleep(0.01)
    else:
        raise AssertionError("migration did not finish")

    assert result.phase.value == "switched"
    target = Path(result.target_root)
    assert (target / "workspaces" / "move-me" / "source.pdf").is_file()
    assert (target / ".engine" / "jobs" / "old.json").is_file()
    assert StateRepository(WorkspacePaths(target)).list_books() == ("move-me",)
    assert source_root.is_dir()

    WorkspaceMigrationService.cleanup_pending_source(
        Settings(
            workspace_root=target,
            managed_by="user",
            settings_path=settings_path,
            allow_pending_cleanup=True,
        ),
        UserSettingsStore(settings_path),
    )
    assert not source_root.exists()
