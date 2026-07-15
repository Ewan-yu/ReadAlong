from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class FrozenModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class StepId(str, Enum):
    PAGES = "pages"
    OCR = "ocr"
    PROOFREAD = "proofread"
    AUDIO = "audio"
    EXPORT = "export"


class StepStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"
    STALE = "stale"


class AttemptStatus(str, Enum):
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELLED = "cancelled"
    INTERRUPTED = "interrupted"


class PipelineErrorInfo(FrozenModel):
    code: str
    message: str
    details: dict[str, Any] = Field(default_factory=dict)


class OutputFile(FrozenModel):
    path: str
    size: int = Field(ge=0)
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")


class StepSuccess(FrozenModel):
    revision_id: str
    output_root: str
    params_hash: str = Field(pattern=r"^[0-9a-f]{64}$")
    input_fingerprint: str = Field(pattern=r"^[0-9a-f]{64}$")
    output_fingerprint: str = Field(pattern=r"^[0-9a-f]{64}$")
    outputs: tuple[OutputFile, ...]
    completed_at: datetime


class ActiveAttempt(FrozenModel):
    job_id: str
    params_hash: str = Field(pattern=r"^[0-9a-f]{64}$")
    input_fingerprint: str = Field(pattern=r"^[0-9a-f]{64}$")
    base_status: StepStatus
    base_stale_reason: "InvalidationReason | None" = None
    started_at: datetime


class AttemptSummary(FrozenModel):
    job_id: str
    status: AttemptStatus
    started_at: datetime
    finished_at: datetime
    error: PipelineErrorInfo | None = None


class InvalidationReason(FrozenModel):
    source_step: StepId
    old_output_fingerprint: str | None = None
    new_output_fingerprint: str
    reason: str
    invalidated_at: datetime


class StepState(FrozenModel):
    status: StepStatus = StepStatus.PENDING
    success: StepSuccess | None = None
    active_attempt: ActiveAttempt | None = None
    last_attempt: AttemptSummary | None = None
    stale_reason: InvalidationReason | None = None

    @model_validator(mode="after")
    def validate_consistency(self) -> "StepState":
        if self.status is StepStatus.RUNNING and self.active_attempt is None:
            raise ValueError("running step requires active_attempt")
        if self.status is not StepStatus.RUNNING and self.active_attempt is not None:
            raise ValueError("only running step may have active_attempt")
        if self.status in (StepStatus.DONE, StepStatus.STALE) and self.success is None:
            raise ValueError("done or stale step requires success")
        if self.status is StepStatus.STALE and self.stale_reason is None:
            raise ValueError("stale step requires stale_reason")
        if self.status is not StepStatus.STALE and self.stale_reason is not None:
            raise ValueError("only stale step may have stale_reason")
        return self


class PipelineSource(FrozenModel):
    pdf_path: str
    pdf_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    original_audio_path: str | None = None
    original_audio_sha256: str | None = Field(default=None, pattern=r"^[0-9a-f]{64}$")


class PipelineState(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[1] = 1
    book_id: str
    revision: int = Field(default=0, ge=0)
    created_at: datetime
    updated_at: datetime
    source: PipelineSource
    steps: dict[StepId, StepState]

    @model_validator(mode="after")
    def validate_steps(self) -> "PipelineState":
        if set(self.steps) != set(StepId):
            raise ValueError("pipeline state must contain every step exactly once")
        return self

    @classmethod
    def new(
        cls,
        *,
        book_id: str,
        pdf_path: str,
        pdf_sha256: str,
        original_audio_path: str | None = None,
        original_audio_sha256: str | None = None,
    ) -> "PipelineState":
        now = utc_now()
        return cls(
            book_id=book_id,
            created_at=now,
            updated_at=now,
            source=PipelineSource(
                pdf_path=pdf_path,
                pdf_sha256=pdf_sha256,
                original_audio_path=original_audio_path,
                original_audio_sha256=original_audio_sha256,
            ),
            steps={step_id: StepState() for step_id in StepId},
        )


class StepResult(FrozenModel):
    outputs: tuple[str, ...]
    summary: dict[str, Any] = Field(default_factory=dict)


class RunStartedResponse(FrozenModel):
    disposition: str = "started"
    job_id: str


class RunSkippedResponse(FrozenModel):
    disposition: str = "skipped"
    state: PipelineState


ActiveAttempt.model_rebuild()
