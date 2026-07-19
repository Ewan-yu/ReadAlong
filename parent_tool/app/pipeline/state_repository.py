from __future__ import annotations

import json
import os
from collections.abc import Callable
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator
from uuid import uuid4

import portalocker
from pydantic import ValidationError

from app.models.errors import PipelineError
from app.models.pipeline import (
    AttemptStatus,
    AttemptSummary,
    PipelineErrorInfo,
    PipelineState,
    StepState,
    StepStatus,
    utc_now,
)
from app.pipeline.paths import WorkspacePaths


class StateRepository:
    def __init__(self, paths: WorkspacePaths, *, lock_timeout: float = 10) -> None:
        self.paths = paths
        self.lock_timeout = lock_timeout

    @contextmanager
    def _lock(self, book_id: str, *, create_parent: bool = True) -> Iterator[None]:
        book_dir = self.paths.book(book_id)
        if create_parent:
            book_dir.mkdir(parents=True, exist_ok=True)
        lock_path = self.paths.state_lock(book_id)
        try:
            with portalocker.Lock(str(lock_path), mode="a+", timeout=self.lock_timeout):
                yield
        except portalocker.exceptions.LockException as exc:
            raise PipelineError(
                "WORKSPACE_LOCK_TIMEOUT",
                "工作区正在被另一个操作使用。",
                details={"book_id": book_id},
                status_code=409,
            ) from exc

    def create(self, state: PipelineState) -> PipelineState:
        with self._lock(state.book_id):
            state_path = self.paths.state(state.book_id)
            if state_path.exists():
                raise PipelineError(
                    "BOOK_ALREADY_EXISTS",
                    "同一书籍工作区已存在。",
                    details={"book_id": state.book_id},
                    status_code=409,
                )
            validated = PipelineState.model_validate(state.model_dump())
            self._write_unlocked(state_path, validated)
            return validated.model_copy(deep=True)

    def load(self, book_id: str) -> PipelineState:
        self._ensure_exists(book_id)
        with self._lock(book_id, create_parent=False):
            return self._load_unlocked(book_id).model_copy(deep=True)

    def update(
        self,
        book_id: str,
        mutate: Callable[[PipelineState], None],
    ) -> PipelineState:
        self._ensure_exists(book_id)
        with self._lock(book_id, create_parent=False):
            state = self._load_unlocked(book_id)
            mutate(state)
            state.revision += 1
            state.updated_at = utc_now()
            validated = PipelineState.model_validate(state.model_dump())
            self._write_unlocked(self.paths.state(book_id), validated)
            return validated.model_copy(deep=True)

    def list_books(self) -> tuple[str, ...]:
        workspace_root = self.paths.workspace_root
        if not workspace_root.exists():
            return ()
        book_ids: list[str] = []
        for candidate in workspace_root.iterdir():
            if not candidate.is_dir() or not (candidate / "state.json").is_file():
                continue
            try:
                if self.paths.book(candidate.name) == candidate.resolve():
                    book_ids.append(candidate.name)
            except PipelineError:
                continue
        return tuple(sorted(book_ids))

    def recover_interrupted(self, book_id: str) -> PipelineState:
        self._ensure_exists(book_id)
        with self._lock(book_id, create_parent=False):
            state = self._load_unlocked(book_id)
            changed = False
            now = utc_now()
            for step_id, step in tuple(state.steps.items()):
                attempt = step.active_attempt
                if attempt is None:
                    continue
                restored_status = attempt.base_status
                restored_reason = attempt.base_stale_reason
                if step.success is None or restored_status in {
                    StepStatus.PENDING,
                    StepStatus.RUNNING,
                }:
                    restored_status = StepStatus.FAILED
                    restored_reason = None
                elif restored_status is not StepStatus.STALE:
                    restored_reason = None
                state.steps[step_id] = StepState(
                    status=restored_status,
                    success=step.success,
                    last_attempt=AttemptSummary(
                        job_id=attempt.job_id,
                        status=AttemptStatus.INTERRUPTED,
                        started_at=attempt.started_at,
                        finished_at=now,
                        error=PipelineErrorInfo(
                            code="PROCESS_INTERRUPTED",
                            message="上次处理因程序退出而中断，可以重新运行。",
                        ),
                    ),
                    stale_reason=restored_reason,
                )
                changed = True
            if not changed:
                return state.model_copy(deep=True)
            state.revision += 1
            state.updated_at = now
            validated = PipelineState.model_validate(state.model_dump())
            self._write_unlocked(self.paths.state(book_id), validated)
            return validated.model_copy(deep=True)

    def _load_unlocked(self, book_id: str) -> PipelineState:
        state_path = self.paths.state(book_id)
        if not state_path.is_file():
            raise PipelineError(
                "BOOK_NOT_FOUND",
                "没有找到该书籍工作区。",
                details={"book_id": book_id},
                status_code=404,
            )
        try:
            raw = json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise PipelineError(
                "WORKSPACE_STATE_CORRUPT",
                "工作区状态文件已损坏，请保留文件并检查日志。",
                details={"book_id": book_id},
                status_code=500,
            ) from exc
        if raw.get("schema_version") != 1:
            raise PipelineError(
                "WORKSPACE_SCHEMA_UNSUPPORTED",
                "工作区状态版本不受支持。",
                details={"book_id": book_id, "schema_version": raw.get("schema_version")},
                status_code=409,
            )
        try:
            return PipelineState.model_validate(raw)
        except ValidationError as exc:
            raise PipelineError(
                "WORKSPACE_STATE_CORRUPT",
                "工作区状态文件内容不完整，请保留文件并检查日志。",
                details={"book_id": book_id},
                status_code=500,
            ) from exc

    def _ensure_exists(self, book_id: str) -> None:
        if not self.paths.state(book_id).is_file():
            raise PipelineError(
                "BOOK_NOT_FOUND",
                "没有找到该书籍工作区。",
                details={"book_id": book_id},
                status_code=404,
            )

    @staticmethod
    def _write_unlocked(path: Path, state: PipelineState) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{uuid4().hex}.tmp")
        try:
            payload = state.model_dump_json(exclude_none=False)
            with temporary.open("w", encoding="utf-8", newline="\n") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
