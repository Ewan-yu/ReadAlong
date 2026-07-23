from __future__ import annotations

from app.models.errors import PipelineError
from app.models.pipeline import InvalidationReason, StepId, StepState, StepStatus, StepSuccess, utc_now
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.state_repository import StateRepository


class OriginalAudioReviewService:
    """Promote a listened-to separation candidate without replacing it in place."""

    def __init__(self, states: StateRepository, artifacts: ArtifactStore) -> None:
        self.states = states
        self.artifacts = artifacts

    def confirm_current(self, book_id: str) -> StepSuccess:
        state = self.states.load(book_id)
        candidate_state = state.steps[StepId.ORIGINAL_AUDIO]
        candidate = candidate_state.success
        if candidate_state.status is not StepStatus.DONE or candidate is None:
            raise PipelineError("ORIGINAL_AUDIO_CANDIDATE_NOT_READY", "没有可确认的原音分离候选。", status_code=409)
        if not self.artifacts.verify(book_id, StepId.ORIGINAL_AUDIO, candidate):
            raise PipelineError("ORIGINAL_AUDIO_CANDIDATE_INVALID", "原音分离候选已损坏，请重新分离。", status_code=409)
        published = self.artifacts.promote_candidate(book_id, candidate.revision_id, candidate)
        now = utc_now()

        def mutate(updated) -> None:
            latest = updated.steps[StepId.ORIGINAL_AUDIO].success
            if latest is None or latest.revision_id != candidate.revision_id:
                raise PipelineError("PIPELINE_STATE_CHANGED", "候选已被新的分离任务替换，请重新试听。", status_code=409)
            updated.original_audio_review = updated.original_audio_review.model_copy(
                update={"confirmed": published, "confirmed_at": now}
            )
            exported = updated.steps[StepId.EXPORT]
            if exported.success is not None and exported.status is not StepStatus.RUNNING:
                updated.steps[StepId.EXPORT] = StepState(
                    status=StepStatus.STALE,
                    success=exported.success,
                    last_attempt=exported.last_attempt,
                    stale_reason=InvalidationReason(
                        source_step=StepId.ORIGINAL_AUDIO,
                        old_output_fingerprint=exported.success.output_fingerprint,
                        new_output_fingerprint=published.output_fingerprint,
                        reason="已确认新的原音分离结果，需要重新导出资源包。",
                        invalidated_at=now,
                    ),
                )

        self.states.update(book_id, mutate)
        return published
