from __future__ import annotations

from datetime import datetime
from enum import Enum

from pydantic import Field, model_validator

from app.models.pipeline import FrozenModel, PipelineErrorInfo, StepId


class JobStatus(str, Enum):
    QUEUED = "queued"
    RUNNING = "running"
    CANCELLING = "cancelling"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELLED = "cancelled"
    INTERRUPTED = "interrupted"

    @property
    def terminal(self) -> bool:
        return self in {
            JobStatus.SUCCEEDED,
            JobStatus.FAILED,
            JobStatus.CANCELLED,
            JobStatus.INTERRUPTED,
        }


class JobSnapshot(FrozenModel):
    job_id: str
    book_id: str
    step_id: StepId
    status: JobStatus
    progress: float = Field(ge=0, le=1)
    message: str
    cancel_requested: bool = False
    created_at: datetime
    updated_at: datetime
    started_at: datetime | None = None
    finished_at: datetime | None = None
    error: PipelineErrorInfo | None = None

    @model_validator(mode="after")
    def validate_terminal_time(self) -> "JobSnapshot":
        if self.status.terminal and self.finished_at is None:
            raise ValueError("terminal job requires finished_at")
        if not self.status.terminal and self.finished_at is not None:
            raise ValueError("nonterminal job cannot have finished_at")
        return self
