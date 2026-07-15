from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ValidationError

from app.models.errors import PipelineError
from app.models.pipeline import (
    ActiveAttempt,
    AttemptStatus,
    AttemptSummary,
    InvalidationReason,
    PipelineErrorInfo,
    PipelineState,
    StepId,
    StepState,
    StepStatus,
    StepSuccess,
    utc_now,
)
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.definitions import (
    STEP_DEPENDENCIES,
    CancellationToken,
    PipelineStep,
    ProgressReporter,
    StepRegistry,
    StepRunContext,
    transitive_successors,
)
from app.pipeline.hashing import canonical_sha256, input_fingerprint
from app.pipeline.state_repository import StateRepository


@dataclass(frozen=True)
class RunPlan:
    book_id: str
    step_id: StepId
    step: PipelineStep
    params: BaseModel
    params_hash: str
    input_fingerprint: str
    dependency_outputs: dict[StepId, Path]
    state_revision: int


@dataclass(frozen=True)
class SkippedRun:
    state: PipelineState


@dataclass(frozen=True)
class PreparedRun:
    plan: RunPlan
    job_id: str
    staging_dir: Path


class PipelineEngine:
    def __init__(
        self,
        states: StateRepository,
        artifacts: ArtifactStore,
        registry: StepRegistry,
    ) -> None:
        self.states = states
        self.artifacts = artifacts
        self.registry = registry

    def plan(
        self,
        book_id: str,
        step_id: StepId,
        raw_params: dict[str, Any],
        *,
        force: bool = False,
    ) -> RunPlan | SkippedRun:
        step = self.registry.get(step_id)
        state = self.states.load(book_id)
        dependency_outputs: dict[StepId, Path] = {}
        dependency_fingerprints: dict[str, str] = {}
        for dependency in STEP_DEPENDENCIES[step_id]:
            dependency_state = state.steps[dependency]
            if (
                dependency_state.status is not StepStatus.DONE
                or dependency_state.success is None
                or not self.artifacts.verify(book_id, dependency, dependency_state.success)
            ):
                raise PipelineError(
                    "STEP_DEPENDENCY_NOT_READY",
                    "需要先完成上游处理步骤。",
                    details={"step_id": step_id.value, "dependency": dependency.value},
                    status_code=409,
                )
            dependency_outputs[dependency] = (
                self.artifacts.paths.book(book_id) / dependency_state.success.output_root
            )
            dependency_fingerprints[dependency.value] = (
                dependency_state.success.output_fingerprint
            )
        try:
            params = step.params_model.model_validate(raw_params)
        except ValidationError as exc:
            raise PipelineError(
                "INVALID_STEP_PARAMS",
                "处理参数不合法。",
                details={"step_id": step_id.value, "errors": exc.errors(include_url=False)},
                status_code=422,
            ) from exc
        params_hash = canonical_sha256(params.model_dump(mode="json"))
        fingerprint = input_fingerprint(
            step_id=step_id.value,
            implementation_version=step.implementation_version,
            params_hash=params_hash,
            source_fingerprint=state.source.pdf_sha256 if step_id is StepId.PAGES else None,
            dependencies=dependency_fingerprints,
        )
        current = state.steps[step_id]
        same_input = (
            current.success is not None
            and current.success.params_hash == params_hash
            and current.success.input_fingerprint == fingerprint
        )
        if (
            not force
            and current.status is StepStatus.DONE
            and same_input
            and current.success is not None
            and self.artifacts.verify(book_id, step_id, current.success)
        ):
            return SkippedRun(state=state)
        if current.status is StepStatus.RUNNING:
            raise PipelineError(
                "JOB_ALREADY_RUNNING",
                "该处理步骤正在运行。",
                details={"step_id": step_id.value},
                status_code=409,
            )
        return RunPlan(
            book_id=book_id,
            step_id=step_id,
            step=step,
            params=params,
            params_hash=params_hash,
            input_fingerprint=fingerprint,
            dependency_outputs=dependency_outputs,
            state_revision=state.revision,
        )

    def begin(self, plan: RunPlan, job_id: str) -> PreparedRun:
        staging = self.artifacts.create_staging(plan.book_id, job_id)

        def mutate(state: PipelineState) -> None:
            if state.revision != plan.state_revision:
                raise PipelineError(
                    "PIPELINE_STATE_CHANGED",
                    "工作区状态已经变化，请重新提交。",
                    status_code=409,
                )
            current = state.steps[plan.step_id]
            if current.status is StepStatus.RUNNING:
                raise PipelineError(
                    "JOB_ALREADY_RUNNING",
                    "该处理步骤正在运行。",
                    status_code=409,
                )
            state.steps[plan.step_id] = StepState(
                status=StepStatus.RUNNING,
                success=current.success,
                active_attempt=ActiveAttempt(
                    job_id=job_id,
                    params_hash=plan.params_hash,
                    input_fingerprint=plan.input_fingerprint,
                    base_status=current.status,
                    base_stale_reason=current.stale_reason,
                    started_at=utc_now(),
                ),
                last_attempt=current.last_attempt,
            )

        try:
            self.states.update(plan.book_id, mutate)
        except Exception:
            self.artifacts.cleanup_staging(staging)
            raise
        return PreparedRun(plan=plan, job_id=job_id, staging_dir=staging)

    def execute(
        self,
        prepared: PreparedRun,
        reporter: ProgressReporter,
        cancellation: CancellationToken,
    ) -> StepSuccess:
        plan = prepared.plan
        published_root: str | None = None
        try:
            cancellation.raise_if_cancelled()
            context = StepRunContext(
                book_id=plan.book_id,
                workspace_dir=self.artifacts.paths.book(plan.book_id),
                staging_dir=prepared.staging_dir,
                dependency_outputs=plan.dependency_outputs,
                progress=reporter,
                cancellation=cancellation,
            )
            result = plan.step.run(context, plan.params)
            cancellation.raise_if_cancelled()
            outputs, output_fingerprint = self.artifacts.build_manifest(
                prepared.staging_dir, result.outputs
            )
            cancellation.raise_if_cancelled()
            revision_id = f"r-{output_fingerprint[:8]}-{prepared.job_id.split('-', 1)[0]}"
            published_root = self.artifacts.publish(
                plan.book_id, plan.step_id, revision_id, prepared.staging_dir
            )
            now = utc_now()
            success = StepSuccess(
                revision_id=revision_id,
                output_root=published_root,
                params_hash=plan.params_hash,
                input_fingerprint=plan.input_fingerprint,
                output_fingerprint=output_fingerprint,
                outputs=outputs,
                completed_at=now,
            )

            def commit(state: PipelineState) -> None:
                current = state.steps[plan.step_id]
                active = current.active_attempt
                if active is None or active.job_id != prepared.job_id:
                    raise PipelineError(
                        "PIPELINE_STATE_CHANGED",
                        "任务状态已经变化，不能发布产物。",
                        status_code=409,
                    )
                old_fingerprint = (
                    current.success.output_fingerprint if current.success is not None else None
                )
                state.steps[plan.step_id] = StepState(
                    status=StepStatus.DONE,
                    success=success,
                    last_attempt=AttemptSummary(
                        job_id=prepared.job_id,
                        status=AttemptStatus.SUCCEEDED,
                        started_at=active.started_at,
                        finished_at=now,
                    ),
                )
                for successor in transitive_successors(plan.step_id):
                    downstream = state.steps[successor]
                    if downstream.success is None:
                        continue
                    state.steps[successor] = StepState(
                        status=StepStatus.STALE,
                        success=downstream.success,
                        last_attempt=downstream.last_attempt,
                        stale_reason=InvalidationReason(
                            source_step=plan.step_id,
                            old_output_fingerprint=old_fingerprint,
                            new_output_fingerprint=output_fingerprint,
                            reason=f"{plan.step_id.value} 发布了新产物修订。",
                            invalidated_at=now,
                        ),
                    )

            committed = self.states.update(plan.book_id, commit)
            self.artifacts.cleanup_unreferenced(committed)
            return success
        except Exception as exc:
            if published_root is not None:
                self.artifacts.discard_revision(plan.book_id, published_root)
            self.artifacts.cleanup_staging(prepared.staging_dir)
            self._rollback(prepared, exc)
            raise

    def _rollback(self, prepared: PreparedRun, exc: Exception) -> None:
        now = utc_now()
        cancelled = isinstance(exc, PipelineError) and exc.code == "JOB_CANCELLED"
        error = self._error_info(exc)

        def mutate(state: PipelineState) -> None:
            current = state.steps[prepared.plan.step_id]
            active = current.active_attempt
            if active is None or active.job_id != prepared.job_id:
                return
            restored_status = active.base_status
            restored_reason = active.base_stale_reason
            if current.success is None or restored_status in {
                StepStatus.PENDING,
                StepStatus.RUNNING,
            }:
                restored_status = StepStatus.FAILED
                restored_reason = None
            elif restored_status is not StepStatus.STALE:
                restored_reason = None
            state.steps[prepared.plan.step_id] = StepState(
                status=restored_status,
                success=current.success,
                last_attempt=AttemptSummary(
                    job_id=prepared.job_id,
                    status=AttemptStatus.CANCELLED if cancelled else AttemptStatus.FAILED,
                    started_at=active.started_at,
                    finished_at=now,
                    error=error,
                ),
                stale_reason=restored_reason,
            )

        self.states.update(prepared.plan.book_id, mutate)

    @staticmethod
    def _error_info(exc: Exception) -> PipelineErrorInfo:
        if isinstance(exc, PipelineError):
            return PipelineErrorInfo(code=exc.code, message=exc.message, details=exc.details)
        return PipelineErrorInfo(
            code="INTERNAL_PIPELINE_ERROR",
            message="处理步骤发生内部错误，请查看日志后重试。",
        )
