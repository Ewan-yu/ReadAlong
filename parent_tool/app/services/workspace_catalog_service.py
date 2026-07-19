from __future__ import annotations

import os
import shutil
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from pydantic import ValidationError

from app.jobs.manager import JobManager
from app.config import Settings
from app.models.errors import PipelineError
from app.models.ocr import OcrSentences
from app.models.pages import PagePlan
from app.models.pipeline import PipelineErrorInfo, PipelineState, StepId, StepStatus
from app.models.workspace_catalog import (
    StorageInfo,
    WorkspaceLifecycleStatus,
    WorkspaceListResponse,
    WorkspaceMetadata,
    WorkspaceSummary,
)
from app.pipeline.paths import WorkspacePaths, ensure_within
from app.pipeline.state_repository import StateRepository


class WorkspaceCatalogService:
    def __init__(
        self,
        paths: WorkspacePaths,
        states: StateRepository,
        jobs: JobManager,
        settings: Settings,
    ) -> None:
        self.paths = paths
        self.states = states
        self.jobs = jobs
        self.settings = settings

    def list(self) -> WorkspaceListResponse:
        summaries = tuple(self.summary(book_id) for book_id in self.states.list_books())
        ordered = tuple(sorted(summaries, key=lambda item: item.updated_at, reverse=True))
        return WorkspaceListResponse(
            workspaces=ordered,
            total_size_bytes=sum(item.size_bytes for item in ordered),
        )

    def summary(self, book_id: str) -> WorkspaceSummary:
        book_dir = self.paths.book(book_id)
        size_bytes = self._directory_size(book_dir)
        try:
            state = self.states.load(book_id)
        except PipelineError as exc:
            if exc.code == "BOOK_NOT_FOUND":
                raise
            timestamp = datetime.fromtimestamp(
                self.paths.state(book_id).stat().st_mtime,
                tz=timezone.utc,
            )
            return WorkspaceSummary(
                book_id=book_id,
                display_name=book_id,
                created_at=timestamp,
                updated_at=timestamp,
                lifecycle_status=WorkspaceLifecycleStatus.CORRUPT,
                current_step=StepId.PAGES,
                completed_steps=0,
                continue_path=f"/books/{book_id}/pages",
                size_bytes=size_bytes,
                error=PipelineErrorInfo(code=exc.code, message=exc.message, details=exc.details),
            )

        metadata = self._metadata(book_id)
        current_step = self._current_step(state)
        current = state.steps[current_step]
        return WorkspaceSummary(
            book_id=book_id,
            display_name=metadata.display_name if metadata else book_id,
            source_filename=metadata.source_filename if metadata else None,
            created_at=state.created_at,
            updated_at=state.updated_at,
            last_opened_at=metadata.last_opened_at if metadata else None,
            lifecycle_status=self._lifecycle(state),
            current_step=current_step,
            step_status=current.status,
            completed_steps=sum(
                step.status is StepStatus.DONE for step in state.steps.values()
            ),
            continue_path=f"/books/{book_id}/{self._route_segment(current_step)}",
            page_count=self._page_count(state),
            sentence_count=self._sentence_count(state),
            exported=state.steps[StepId.EXPORT].status is StepStatus.DONE,
            size_bytes=size_bytes,
            error=self._last_error(state),
        )

    def storage(self) -> StorageInfo:
        self.paths.root.mkdir(parents=True, exist_ok=True)
        workspaces = self.list()
        usage = shutil.disk_usage(self.paths.root)
        return StorageInfo(
            workspace_root=str(self.paths.root),
            managed_by=self.settings.managed_by,
            workspace_count=len(workspaces.workspaces),
            used_bytes=workspaces.total_size_bytes,
            disk_total_bytes=usage.total,
            disk_free_bytes=usage.free,
        )

    def move_to_trash(self, book_id: str) -> Path:
        target = self.paths.book(book_id)
        if not self.paths.state(book_id).is_file():
            raise PipelineError(
                "BOOK_NOT_FOUND",
                "没有找到该书籍工作区。",
                details={"book_id": book_id},
                status_code=404,
            )
        trash_root = ensure_within(self.paths.root, self.paths.root / ".trash")
        trash_root.mkdir(parents=True, exist_ok=True)
        trash = ensure_within(trash_root, trash_root / f"{book_id}-{uuid4().hex}")
        with self.jobs.maintenance():
            try:
                target.rename(trash)
            except OSError as exc:
                raise PipelineError(
                    "WORKSPACE_DELETE_FAILED",
                    "项目文件正在使用或无法删除，请关闭相关文件后重试。",
                    details={"book_id": book_id},
                    status_code=409,
                ) from exc
        return trash

    def purge_trash(self, target: Path) -> None:
        trash_root = ensure_within(self.paths.root, self.paths.root / ".trash")
        candidate = ensure_within(trash_root, target)
        if candidate.exists():
            shutil.rmtree(candidate, ignore_errors=True)

    def cleanup_trash(self) -> None:
        trash_root = self.paths.root / ".trash"
        if not trash_root.is_dir():
            return
        for candidate in trash_root.iterdir():
            if candidate.is_dir():
                self.purge_trash(candidate)

    def write_metadata(self, metadata: WorkspaceMetadata) -> None:
        path = ensure_within(
            self.paths.book(metadata.book_id),
            self.paths.book(metadata.book_id) / "workspace.json",
        )
        temporary = path.with_name(f".{path.name}.{uuid4().hex}.tmp")
        try:
            with temporary.open("w", encoding="utf-8", newline="\n") as stream:
                stream.write(metadata.model_dump_json(exclude_none=False))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    def _metadata(self, book_id: str) -> WorkspaceMetadata | None:
        path = self.paths.book(book_id) / "workspace.json"
        if not path.is_file():
            return None
        try:
            return WorkspaceMetadata.model_validate_json(path.read_text(encoding="utf-8"))
        except (OSError, ValidationError, ValueError):
            return None

    @staticmethod
    def _current_step(state: PipelineState) -> StepId:
        for step_id in (StepId.PAGES, StepId.PROOFREAD, StepId.AUDIO):
            if state.steps[step_id].status is not StepStatus.DONE:
                return step_id
        return StepId.EXPORT

    @staticmethod
    def _route_segment(step_id: StepId) -> str:
        return {
            StepId.PAGES: "pages",
            StepId.PROOFREAD: "proofread",
            StepId.AUDIO: "audio",
            StepId.EXPORT: "export",
            StepId.OCR: "proofread",
        }[step_id]

    @staticmethod
    def _lifecycle(state: PipelineState) -> WorkspaceLifecycleStatus:
        statuses = {step.status for step in state.steps.values()}
        if StepStatus.RUNNING in statuses:
            return WorkspaceLifecycleStatus.RUNNING
        if state.steps[StepId.EXPORT].status is StepStatus.DONE:
            return WorkspaceLifecycleStatus.COMPLETED
        if StepStatus.FAILED in statuses:
            return WorkspaceLifecycleStatus.FAILED
        if StepStatus.STALE in statuses:
            return WorkspaceLifecycleStatus.STALE
        return WorkspaceLifecycleStatus.IN_PROGRESS

    def _page_count(self, state: PipelineState) -> int | None:
        success = state.steps[StepId.PAGES].success
        if success is None:
            return None
        try:
            plan = PagePlan.model_validate_json(
                (self.paths.book(state.book_id) / success.output_root / "page_plan.json").read_text(
                    encoding="utf-8"
                )
            )
            return sum(len(page.outputs) for page in plan.pages)
        except (OSError, ValueError):
            return None

    def _sentence_count(self, state: PipelineState) -> int | None:
        success = state.steps[StepId.PROOFREAD].success
        if success is None:
            return None
        try:
            sentences = OcrSentences.model_validate_json(
                (
                    self.paths.book(state.book_id)
                    / success.output_root
                    / "sentences_final.json"
                ).read_text(encoding="utf-8")
            )
            return len(sentences.sentences)
        except (OSError, ValueError):
            return None

    @staticmethod
    def _last_error(state: PipelineState) -> PipelineErrorInfo | None:
        attempts = tuple(
            attempt
            for step in state.steps.values()
            if (attempt := step.last_attempt) is not None and attempt.error is not None
        )
        if not attempts:
            return None
        return max(attempts, key=lambda item: item.finished_at).error

    @staticmethod
    def _directory_size(root: Path) -> int:
        if not root.is_dir():
            return 0
        total = 0
        try:
            for directory, _names, filenames in os.walk(root):
                for filename in filenames:
                    try:
                        total += (Path(directory) / filename).stat().st_size
                    except OSError:
                        continue
        except OSError:
            return total
        return total
