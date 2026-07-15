from __future__ import annotations

import os
from pathlib import Path
from threading import RLock
from typing import Any
from uuid import uuid4

from pydantic import ValidationError

from app.models.errors import PipelineError
from app.models.jobs import JobSnapshot, JobStatus
from app.models.pipeline import PipelineErrorInfo, utc_now
from app.pipeline.paths import WorkspacePaths


class JobRepository:
    def __init__(self, paths: WorkspacePaths) -> None:
        self.paths = paths
        self._lock = RLock()

    def create(self, snapshot: JobSnapshot) -> JobSnapshot:
        with self._lock:
            path = self.paths.job(snapshot.job_id)
            if path.exists():
                raise PipelineError(
                    "JOB_ALREADY_EXISTS",
                    "任务记录已经存在。",
                    details={"job_id": snapshot.job_id},
                    status_code=409,
                )
            self._write(path, snapshot)
            return snapshot

    def load(self, job_id: str) -> JobSnapshot:
        with self._lock:
            path = self.paths.job(job_id)
            if not path.is_file():
                raise PipelineError(
                    "JOB_NOT_FOUND",
                    "没有找到该任务。",
                    details={"job_id": job_id},
                    status_code=404,
                )
            try:
                return JobSnapshot.model_validate_json(path.read_text(encoding="utf-8"))
            except (OSError, ValidationError, ValueError) as exc:
                raise PipelineError(
                    "JOB_STATE_CORRUPT",
                    "任务状态文件已损坏。",
                    details={"job_id": job_id},
                    status_code=500,
                ) from exc

    def replace(self, job_id: str, **updates: Any) -> JobSnapshot:
        with self._lock:
            current = self.load(job_id)
            payload = current.model_dump()
            payload.update(updates)
            snapshot = JobSnapshot.model_validate(payload)
            self._write(self.paths.job(job_id), snapshot)
            return snapshot

    def list(self) -> tuple[JobSnapshot, ...]:
        with self._lock:
            if not self.paths.jobs.is_dir():
                return ()
            snapshots: list[JobSnapshot] = []
            for path in sorted(self.paths.jobs.glob("*.json")):
                snapshots.append(self.load(path.stem))
            return tuple(snapshots)

    def recover_nonterminal(self) -> tuple[JobSnapshot, ...]:
        recovered: list[JobSnapshot] = []
        for snapshot in self.list():
            if snapshot.status.terminal:
                continue
            now = utc_now()
            recovered.append(
                self.replace(
                    snapshot.job_id,
                    status=JobStatus.INTERRUPTED,
                    updated_at=now,
                    finished_at=now,
                    error=PipelineErrorInfo(
                        code="PROCESS_INTERRUPTED",
                        message="任务因程序退出而中断，可以重新运行。",
                    ),
                )
            )
        return tuple(recovered)

    @staticmethod
    def _write(path: Path, snapshot: JobSnapshot) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{uuid4().hex}.tmp")
        try:
            with temporary.open("w", encoding="utf-8", newline="\n") as stream:
                stream.write(snapshot.model_dump_json(exclude_none=False))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
