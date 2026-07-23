from __future__ import annotations

import json
from pathlib import Path, PurePosixPath

from app.models.errors import PipelineError
from app.models.original_audio_workspace import (
    OriginalAudioCandidateAssets,
    OriginalAudioWorkspaceResponse,
)
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
                update={
                    "confirmed": published,
                    "confirmed_at": now,
                    "background_disabled": False,
                }
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

    def disable_background(self, book_id: str) -> None:
        now = utc_now()

        def mutate(updated) -> None:
            if not updated.source.original_audio_path:
                raise PipelineError("ORIGINAL_AUDIO_NOT_UPLOADED", "没有原音项目无需设置背景轨。", status_code=409)
            updated.original_audio_review = updated.original_audio_review.model_copy(
                update={"background_disabled": True}
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
                        new_output_fingerprint="0" * 64,
                        reason="已选择不使用背景轨，需要重新导出资源包。",
                        invalidated_at=now,
                    ),
                )

        self.states.update(book_id, mutate)

    def workspace(self, book_id: str) -> OriginalAudioWorkspaceResponse:
        state = self.states.load(book_id)
        if not state.source.original_audio_path:
            return OriginalAudioWorkspaceResponse(available=False, status="not_available")
        step = state.steps[StepId.ORIGINAL_AUDIO]
        confirmed = state.original_audio_review.confirmed
        if state.original_audio_review.background_disabled:
            return OriginalAudioWorkspaceResponse(
                available=True,
                source_filename=Path(state.source.original_audio_path).name,
                status="voice_only",
                candidate_revision_id=step.success.revision_id if step.success else None,
                confirmed_revision_id=confirmed.revision_id if confirmed else None,
                message="已选择纯人声作品；背景轨不会进入下一次导出。",
            )
        if step.status is StepStatus.PENDING:
            return OriginalAudioWorkspaceResponse(
                available=True,
                source_filename=Path(state.source.original_audio_path).name,
                status="not_processed",
            )
        if step.status is StepStatus.RUNNING:
            return OriginalAudioWorkspaceResponse(
                available=True,
                source_filename=Path(state.source.original_audio_path).name,
                status="processing",
                candidate_revision_id=step.success.revision_id if step.success else None,
            )
        if step.status is StepStatus.FAILED:
            return OriginalAudioWorkspaceResponse(
                available=True,
                source_filename=Path(state.source.original_audio_path).name,
                status="failed",
                message=step.last_attempt.error.message if step.last_attempt and step.last_attempt.error else "分离任务未完成。",
            )
        if step.status is StepStatus.STALE:
            return OriginalAudioWorkspaceResponse(
                available=True,
                source_filename=Path(state.source.original_audio_path).name,
                status="stale",
                message="校对或原音已变化，请重新分离后再试听。",
            )
        candidate = step.success
        if candidate is None or not self.artifacts.verify(book_id, StepId.ORIGINAL_AUDIO, candidate):
            return OriginalAudioWorkspaceResponse(
                available=True,
                source_filename=Path(state.source.original_audio_path).name,
                status="failed",
                message="分离候选已损坏，请重新分离。",
            )
        try:
            root = self.artifacts.paths.book(book_id) / candidate.output_root
            report = json.loads((root / "separation_report.json").read_text(encoding="utf-8"))
            assets = OriginalAudioCandidateAssets(
                vocals_preview="preview/vocals.ogg",
                background_preview="preview/background.ogg",
                waveform_original="waveform/original.json",
                waveform_vocals="waveform/vocals.json",
                waveform_background="waveform/background.json",
            )
            required = tuple(assets.model_dump().values())
            declared = {item.path for item in candidate.outputs}
            if not all(path in declared and (root / path).is_file() for path in required):
                raise ValueError
            return OriginalAudioWorkspaceResponse(
                available=True,
                source_filename=Path(state.source.original_audio_path).name,
                status="confirmed" if confirmed and confirmed.revision_id == candidate.revision_id else "ready_for_review",
                candidate_revision_id=candidate.revision_id,
                confirmed_revision_id=confirmed.revision_id if confirmed else None,
                model=report.get("model") if isinstance(report.get("model"), str) else None,
                duration_ms=report.get("duration_ms") if isinstance(report.get("duration_ms"), int) else None,
                assets=assets,
            )
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            return OriginalAudioWorkspaceResponse(
                available=True,
                source_filename=Path(state.source.original_audio_path).name,
                status="failed",
                message="分离候选缺少可试听的轨道，请重新分离。",
            )

    def source_asset(self, book_id: str) -> Path:
        state = self.states.load(book_id)
        if not state.source.original_audio_path or not state.source.original_audio_sha256:
            raise PipelineError("ORIGINAL_AUDIO_NOT_UPLOADED", "没有可试听的原音文件。", status_code=404)
        root = self.artifacts.paths.book(book_id)
        path = (root / state.source.original_audio_path).resolve(strict=False)
        if not path.is_relative_to(root) or not path.is_file():
            raise PipelineError("ORIGINAL_AUDIO_MISSING", "原音文件不存在。", status_code=404)
        from app.pipeline.hashing import file_sha256

        if file_sha256(path) != state.source.original_audio_sha256:
            raise PipelineError("ORIGINAL_AUDIO_HASH_MISMATCH", "原音文件已变化，请重新导入。", status_code=409)
        return path

    def candidate_asset(self, book_id: str, candidate_id: str, asset_path: str) -> Path:
        state = self.states.load(book_id)
        candidate = state.steps[StepId.ORIGINAL_AUDIO].success
        if candidate is None or candidate.revision_id != candidate_id or not self.artifacts.verify(book_id, StepId.ORIGINAL_AUDIO, candidate):
            raise PipelineError("ORIGINAL_AUDIO_CANDIDATE_STALE", "分离候选已经更新，请刷新后继续试听。", status_code=409)
        normalized = PurePosixPath(asset_path).as_posix()
        allowed = {item.path for item in candidate.outputs if item.path.startswith(("preview/", "waveform/"))}
        if normalized not in allowed:
            raise PipelineError("ORIGINAL_AUDIO_ASSET_NOT_FOUND", "候选试听资源不存在。", status_code=404)
        root = self.artifacts.paths.book(book_id) / candidate.output_root
        path = (root / Path(*PurePosixPath(normalized).parts)).resolve(strict=False)
        if not path.is_relative_to(root) or not path.is_file():
            raise PipelineError("ORIGINAL_AUDIO_ASSET_NOT_FOUND", "候选试听资源不存在。", status_code=404)
        return path
