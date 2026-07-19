from __future__ import annotations

from datetime import datetime
from enum import Enum

from pydantic import Field

from app.models.pipeline import FrozenModel, PipelineErrorInfo, StepId, StepStatus


class WorkspaceLifecycleStatus(str, Enum):
    IN_PROGRESS = "in_progress"
    RUNNING = "running"
    FAILED = "failed"
    STALE = "stale"
    COMPLETED = "completed"
    CORRUPT = "corrupt"


class WorkspaceMetadata(FrozenModel):
    schema_version: int = 1
    book_id: str
    display_name: str = Field(min_length=1, max_length=200)
    source_filename: str | None = Field(default=None, max_length=260)
    created_at: datetime
    last_opened_at: datetime | None = None


class WorkspaceSummary(FrozenModel):
    book_id: str
    display_name: str
    source_filename: str | None = None
    created_at: datetime
    updated_at: datetime
    last_opened_at: datetime | None = None
    lifecycle_status: WorkspaceLifecycleStatus
    current_step: StepId
    step_status: StepStatus | None = None
    completed_steps: int = Field(ge=0, le=5)
    continue_path: str
    page_count: int | None = Field(default=None, ge=0)
    sentence_count: int | None = Field(default=None, ge=0)
    exported: bool = False
    size_bytes: int = Field(ge=0)
    error: PipelineErrorInfo | None = None


class WorkspaceListResponse(FrozenModel):
    workspaces: tuple[WorkspaceSummary, ...]
    total_size_bytes: int = Field(ge=0)


class StorageInfo(FrozenModel):
    workspace_root: str
    managed_by: str
    workspace_count: int = Field(ge=0)
    used_bytes: int = Field(ge=0)
    disk_total_bytes: int = Field(ge=0)
    disk_free_bytes: int = Field(ge=0)


class StorageMigrationRequest(FrozenModel):
    target_root: str = Field(min_length=1, max_length=2048)


class StorageMigrationPhase(str, Enum):
    QUEUED = "queued"
    PREFLIGHT = "preflight"
    COPYING = "copying"
    VERIFYING = "verifying"
    SWITCHED = "switched"
    FAILED = "failed"


class StorageMigrationStatus(FrozenModel):
    migration_id: str
    target_root: str
    phase: StorageMigrationPhase
    progress: float = Field(ge=0, le=1)
    message: str
    copied_bytes: int = Field(default=0, ge=0)
    total_bytes: int = Field(default=0, ge=0)
    restart_required: bool = False
    error: PipelineErrorInfo | None = None
