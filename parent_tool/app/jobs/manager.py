from __future__ import annotations

import time
import logging
from concurrent.futures import Future, ThreadPoolExecutor
from threading import RLock
from typing import Any, Callable
from uuid import uuid4

from app.jobs.events import EventBus, JobEvent
from app.jobs.repository import JobRepository
from app.models.errors import PipelineError
from app.models.jobs import JobSnapshot, JobStatus
from app.models.pipeline import PipelineErrorInfo, StepId, utc_now
from app.pipeline.definitions import CancellationToken
from app.pipeline.engine import PipelineEngine, PreparedRun, SkippedRun


LOGGER = logging.getLogger(__name__)


class JobManager:
    def __init__(
        self,
        engine: PipelineEngine,
        jobs: JobRepository,
        events: EventBus,
        *,
        executor: ThreadPoolExecutor | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.engine = engine
        self.jobs = jobs
        self.events = events
        self.executor = executor or ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="readalong-pipeline"
        )
        self.clock = clock
        self._lock = RLock()
        self._active_job_id: str | None = None
        self._tokens: dict[str, CancellationToken] = {}
        self._futures: dict[str, Future[None]] = {}
        self._last_persisted_progress: dict[str, float] = {}

    @property
    def active_job_id(self) -> str | None:
        with self._lock:
            return self._active_job_id

    def start(
        self,
        book_id: str,
        step_id: StepId,
        params: dict[str, Any],
        *,
        force: bool = False,
    ) -> JobSnapshot | SkippedRun:
        with self._lock:
            if self._active_job_id is not None:
                raise PipelineError(
                    "JOB_ALREADY_RUNNING",
                    "已有处理任务正在运行。",
                    details={"job_id": self._active_job_id},
                    status_code=409,
                )
            decision = self.engine.plan(book_id, step_id, params, force=force)
            if isinstance(decision, SkippedRun):
                return decision
            job_id = str(uuid4())
            now = utc_now()
            snapshot = JobSnapshot(
                job_id=job_id,
                book_id=book_id,
                step_id=step_id,
                status=JobStatus.QUEUED,
                progress=0,
                message="任务已排队。",
                created_at=now,
                updated_at=now,
            )
            self.jobs.create(snapshot)
            token = CancellationToken()
            try:
                prepared = self.engine.begin(decision, job_id)
            except Exception as exc:
                self._finish_start_failure(snapshot, exc)
                raise
            self._active_job_id = job_id
            self._tokens[job_id] = token
            self._last_persisted_progress[job_id] = self.clock()
            self._publish(snapshot, "snapshot")
            future = self.executor.submit(self._run, prepared, token)
            self._futures[job_id] = future
            future.add_done_callback(lambda _future: self._forget_future(job_id))
            return snapshot

    def get(self, job_id: str) -> JobSnapshot:
        return self.jobs.load(job_id)

    def cancel(self, job_id: str) -> JobSnapshot:
        with self._lock:
            current = self.jobs.load(job_id)
            if current.status.terminal:
                return current
            token = self._tokens.get(job_id)
            if token is not None:
                token.request()
            now = utc_now()
            cancelling = self.jobs.replace(
                job_id,
                status=JobStatus.CANCELLING,
                cancel_requested=True,
                message="正在取消任务。",
                updated_at=now,
            )
            self._publish(cancelling, "snapshot")
            return cancelling

    def wait(self, job_id: str, *, timeout: float | None = None) -> JobSnapshot:
        with self._lock:
            future = self._futures.get(job_id)
        if future is not None:
            future.result(timeout=timeout)
        return self.jobs.load(job_id)

    def recover(self) -> tuple[JobSnapshot, ...]:
        return self.jobs.recover_nonterminal()

    def shutdown(self) -> None:
        active = self.active_job_id
        if active is not None:
            try:
                self.cancel(active)
            except PipelineError:
                pass
        self.executor.shutdown(wait=True, cancel_futures=True)

    def _run(self, prepared: PreparedRun, token: CancellationToken) -> None:
        job_id = prepared.job_id
        try:
            now = utc_now()
            running_status = JobStatus.CANCELLING if token.requested else JobStatus.RUNNING
            running = self.jobs.replace(
                job_id,
                status=running_status,
                message="正在处理。" if not token.requested else "正在取消任务。",
                started_at=now,
                updated_at=now,
                cancel_requested=token.requested,
            )
            self._publish(running, "snapshot")
            self.engine.execute(
                prepared,
                lambda progress, message: self._report(job_id, progress, message),
                token,
            )
            completed_at = utc_now()
            completed = self._finish_terminal(
                job_id,
                status=JobStatus.SUCCEEDED,
                progress=1,
                message="处理完成。",
                updated_at=completed_at,
                finished_at=completed_at,
                error=None,
            )
            self._publish(completed, "succeeded")
        except Exception as exc:
            cancelled = isinstance(exc, PipelineError) and exc.code == "JOB_CANCELLED"
            completed_at = utc_now()
            error = self._error_info(exc)
            completed = self._finish_terminal(
                job_id,
                status=JobStatus.CANCELLED if cancelled else JobStatus.FAILED,
                message="任务已取消。" if cancelled else "处理失败。",
                cancel_requested=cancelled or token.requested,
                updated_at=completed_at,
                finished_at=completed_at,
                error=error,
            )
            self._publish(completed, "cancelled" if cancelled else "failed")
        finally:
            self._release_slot(job_id)

    def _report(self, job_id: str, progress: float, message: str) -> None:
        with self._lock:
            current = self.jobs.load(job_id)
            bounded = min(1.0, max(current.progress, progress))
            now_clock = self.clock()
            last = self._last_persisted_progress.get(job_id, 0)
            should_persist = bounded >= 1 or now_clock - last >= 0.25
            if should_persist:
                snapshot = self.jobs.replace(
                    job_id,
                    progress=bounded,
                    message=message,
                    updated_at=utc_now(),
                )
                self._last_persisted_progress[job_id] = now_clock
            else:
                snapshot = current.model_copy(
                    update={"progress": bounded, "message": message, "updated_at": utc_now()}
                )
        self._publish(snapshot, "progress")

    def _finish_start_failure(self, snapshot: JobSnapshot, exc: Exception) -> None:
        now = utc_now()
        failed = self.jobs.replace(
            snapshot.job_id,
            status=JobStatus.FAILED,
            message="任务启动失败。",
            updated_at=now,
            finished_at=now,
            error=self._error_info(exc),
        )
        self._publish(failed, "failed")

    def _release_slot(self, job_id: str) -> None:
        with self._lock:
            if self._active_job_id == job_id:
                self._active_job_id = None
            self._tokens.pop(job_id, None)
            self._last_persisted_progress.pop(job_id, None)

    def _finish_terminal(self, job_id: str, **updates: Any) -> JobSnapshot:
        with self._lock:
            completed = self.jobs.replace(job_id, **updates)
            if self._active_job_id == job_id:
                self._active_job_id = None
            self._tokens.pop(job_id, None)
            self._last_persisted_progress.pop(job_id, None)
            return completed

    def _forget_future(self, job_id: str) -> None:
        with self._lock:
            self._futures.pop(job_id, None)

    def _publish(self, snapshot: JobSnapshot, event: str) -> None:
        try:
            self.jobs.append_log(snapshot, event)
        except OSError:
            LOGGER.exception("Failed to append job log for %s", snapshot.job_id)
        self.events.publish(
            JobEvent(event=event, data=snapshot.model_dump(mode="json")),
            job_id=snapshot.job_id,
        )

    @staticmethod
    def _error_info(exc: Exception) -> PipelineErrorInfo:
        if isinstance(exc, PipelineError):
            return PipelineErrorInfo(code=exc.code, message=exc.message, details=exc.details)
        return PipelineErrorInfo(
            code="INTERNAL_PIPELINE_ERROR",
            message="处理任务发生内部错误，请查看日志后重试。",
        )
