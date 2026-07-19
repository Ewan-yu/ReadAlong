from __future__ import annotations

import re
from pathlib import Path
from uuid import UUID

from app.models.errors import PipelineError
from app.models.pipeline import StepId


_BOOK_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,95}$")
_REVISION_ID = re.compile(r"^r-[a-z0-9-]{8,80}$")


def _invalid_path(value: str) -> PipelineError:
    return PipelineError(
        "WORKSPACE_PATH_INVALID",
        "工作区路径不合法。",
        details={"path": value},
        status_code=400,
    )


def ensure_within(root: Path, candidate: Path) -> Path:
    resolved_root = root.resolve()
    resolved_candidate = candidate.resolve(strict=False)
    try:
        resolved_candidate.relative_to(resolved_root)
    except ValueError as exc:
        raise _invalid_path(str(candidate)) from exc
    return resolved_candidate


class WorkspacePaths:
    def __init__(self, root: Path) -> None:
        self.root = root.expanduser().resolve()

    @property
    def engine(self) -> Path:
        return self.root / ".engine"

    @property
    def workspace_root(self) -> Path:
        """Directory containing book workspaces in either supported layout.

        The original M2 layout stored books directly under ``root``.  A data
        root created by the storage migrator uses ``root/workspaces`` instead.
        Detecting the latter keeps existing projects readable without a bulk
        rewrite.
        """
        nested = self.root / "workspaces"
        return nested if nested.is_dir() else self.root

    @property
    def jobs(self) -> Path:
        return self.engine / "jobs"

    @property
    def instance_lock(self) -> Path:
        return self.engine / "instance.lock"

    def job(self, job_id: str) -> Path:
        self.validate_job_id(job_id)
        return ensure_within(self.jobs, self.jobs / f"{job_id}.json")

    def book(self, book_id: str) -> Path:
        if not _BOOK_ID.fullmatch(book_id):
            raise _invalid_path(book_id)
        return ensure_within(self.workspace_root, self.workspace_root / book_id)

    def state(self, book_id: str) -> Path:
        return self.book(book_id) / "state.json"

    def state_lock(self, book_id: str) -> Path:
        return self.book(book_id) / ".state.lock"

    def job_log(self, book_id: str, job_id: str) -> Path:
        self.validate_job_id(job_id)
        return ensure_within(
            self.book(book_id), self.book(book_id) / "logs" / f"{job_id}.jsonl"
        )

    def staging(self, book_id: str, job_id: str) -> Path:
        self.validate_job_id(job_id)
        return ensure_within(self.book(book_id), self.book(book_id) / ".runs" / job_id)

    @staticmethod
    def validate_job_id(job_id: str) -> None:
        try:
            parsed = UUID(job_id)
        except (ValueError, AttributeError) as exc:
            raise _invalid_path(job_id) from exc
        if str(parsed) != job_id.lower() or parsed.version != 4:
            raise _invalid_path(job_id)

    def revisions(self, book_id: str, step_id: StepId) -> Path:
        index = list(StepId).index(step_id) + 1
        directory = {
            StepId.PAGES: "pages",
            StepId.OCR: "ocr",
            StepId.PROOFREAD: "proofread",
            StepId.AUDIO: "audio",
            StepId.EXPORT: "export",
        }[step_id]
        return self.book(book_id) / f"{index:02d}_{directory}" / "revisions"

    def revision(self, book_id: str, step_id: StepId, revision_id: str) -> Path:
        if not _REVISION_ID.fullmatch(revision_id):
            raise _invalid_path(revision_id)
        return ensure_within(
            self.revisions(book_id, step_id), self.revisions(book_id, step_id) / revision_id
        )
