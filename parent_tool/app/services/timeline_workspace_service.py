from __future__ import annotations

import json
from pathlib import Path

from app.models.errors import PipelineError
from app.models.ocr import OcrSentences
from app.models.original_timeline import OriginalTimeline
from app.models.pipeline import StepId, StepStatus
from app.models.timeline_workspace import (
    TimelineReviewUpdateRequest,
    TimelineReviewUpdateResponse,
    TimelineWorkspaceResponse,
    TimelineWorkspaceSentence,
)
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.original_timeline import GENERATION_REPORT_PATH, TIMELINE_PATH
from app.pipeline.paths import WorkspacePaths
from app.pipeline.state_repository import StateRepository
from app.pipeline.timeline_review import (
    load_confirmed_ids,
    replace_confirmed_ids,
)


class TimelineWorkspaceService:
    """Builds the playback-review view for the original-audio lyric timeline.

    The proofread OCR sentences are the reference script.  The timeline is a
    narrated subset, so every unmatched sentence is reported explicitly and the
    parent can confirm it as intentionally skipped ("确认不读") without that
    decision ever leaking into the exported book package.
    """

    def __init__(self, paths: WorkspacePaths, states: StateRepository, artifacts: ArtifactStore) -> None:
        self.paths = paths
        self.states = states
        self.artifacts = artifacts

    def workspace(self, book_id: str) -> TimelineWorkspaceResponse:
        state = self.states.load(book_id)
        if not state.source.original_audio_path:
            return TimelineWorkspaceResponse(available=False, status="not_available")
        proofread = state.steps[StepId.PROOFREAD].success
        if proofread is None:
            return TimelineWorkspaceResponse(available=True, status="not_generated", message="请先完成文本校对。")
        try:
            sentences_root = self.paths.book(book_id) / proofread.output_root
            sentences = OcrSentences.model_validate_json(
                (sentences_root / "sentences_final.json").read_text(encoding="utf-8")
            )
        except (OSError, ValueError):
            return TimelineWorkspaceResponse(
                available=True, status="not_generated", message="校对文本不可读，请重新校对。"
            )

        step = state.steps[StepId.ORIGINAL_TIMELINE]
        if step.status is StepStatus.RUNNING:
            return TimelineWorkspaceResponse(available=True, status="processing")
        if step.status is StepStatus.FAILED:
            return TimelineWorkspaceResponse(
                available=True,
                status="failed",
                message=step.last_attempt.error.message
                if step.last_attempt and step.last_attempt.error
                else "歌词生成未完成。",
            )
        success = step.success
        if success is None:
            return TimelineWorkspaceResponse(available=True, status="not_generated", message="请先生成逐词歌词。")
        if not self.artifacts.verify(book_id, StepId.ORIGINAL_TIMELINE, success):
            return TimelineWorkspaceResponse(
                available=True, status="failed", message="歌词时间线已损坏，请重新生成。"
            )
        revision_root = self.paths.book(book_id) / success.output_root
        try:
            timeline = OriginalTimeline.model_validate_json(
                (revision_root / TIMELINE_PATH).read_text(encoding="utf-8")
            )
        except (OSError, ValueError):
            return TimelineWorkspaceResponse(
                available=True, status="failed", message="歌词时间线已损坏，请重新生成。"
            )
        report = self._load_generation_report(revision_root)
        confirmed = self._load_confirmed_ids(book_id)

        timeline_by_id = {item.sentence_id: item for item in timeline.sentences}
        omissions = self._report_index(report, "omitted")
        manual = self._report_index(report, "manual")
        strategy = self._report_text(report, "strategy")
        rows: list[TimelineWorkspaceSentence] = []
        for sentence in sentences.sentences:
            matched = timeline_by_id.get(sentence.id)
            if matched is not None:
                rows.append(
                    TimelineWorkspaceSentence(
                        sentence_id=sentence.id,
                        page_no=sentence.page_no,
                        seq=sentence.seq,
                        text=sentence.text,
                        status="matched",
                        source=self._manual_source(manual, sentence.id, strategy),
                        start_ms=matched.start_ms,
                        end_ms=matched.end_ms,
                    )
                )
                continue
            omission = omissions.get(sentence.id, {})
            rows.append(
                TimelineWorkspaceSentence(
                    sentence_id=sentence.id,
                    page_no=sentence.page_no,
                    seq=sentence.seq,
                    text=sentence.text,
                    status="confirmed_excluded"
                    if sentence.id in confirmed
                    else "suspect_missing",
                    reason=self._report_text(omission, "reason"),
                    detail=self._report_text(omission, "detail"),
                    previous_matched_id=self._report_text(omission, "previous_matched_id"),
                    next_matched_id=self._report_text(omission, "next_matched_id"),
                    nearby_asr=tuple(
                        word for word in omission.get("nearby_asr", ()) if isinstance(word, str)
                    ),
                )
            )
        return TimelineWorkspaceResponse(
            available=True,
            status="stale" if step.status is StepStatus.STALE else "ready",
            message="校对文本或原音已变化，当前歌词基于旧版本，重新生成后修改才会生效。"
            if step.status is StepStatus.STALE
            else None,
            timeline_revision_id=success.revision_id,
            alignment_strategy=strategy,
            whisper_model=self._report_text(report, "whisper_model"),
            duration_ms=timeline.duration_ms,
            matched_count=sum(1 for item in rows if item.status == "matched"),
            suspect_missing_count=sum(1 for item in rows if item.status == "suspect_missing"),
            confirmed_excluded_count=sum(1 for item in rows if item.status == "confirmed_excluded"),
            sentences=tuple(rows),
        )

    def update_review(self, book_id: str, request: TimelineReviewUpdateRequest) -> TimelineReviewUpdateResponse:
        state = self.states.load(book_id)
        proofread = state.steps[StepId.PROOFREAD].success
        if proofread is None:
            raise PipelineError("TIMELINE_REVIEW_NOT_READY", "请先完成文本校对。", status_code=409)
        try:
            sentences = OcrSentences.model_validate_json(
                (self.paths.book(book_id) / proofread.output_root / "sentences_final.json").read_text(
                    encoding="utf-8"
                )
            )
        except (OSError, ValueError) as exc:
            raise PipelineError(
                "TIMELINE_REVIEW_NOT_READY", "校对文本不可读，请重新校对。", status_code=409
            ) from exc
        known = {sentence.id for sentence in sentences.sentences}
        requested = set(request.confirmed_not_narrated)
        unknown = sorted(requested - known)
        if unknown:
            raise PipelineError(
                "TIMELINE_REVIEW_SENTENCE_UNKNOWN",
                "包含当前校对文本中不存在的句子，请刷新后重试。",
                details={"sentence_ids": unknown[:5]},
                status_code=422,
            )
        confirmed = tuple(sorted(requested))
        replace_confirmed_ids(self.paths.book(book_id), confirmed)
        return TimelineReviewUpdateResponse(confirmed_not_narrated=confirmed)

    def _load_confirmed_ids(self, book_id: str) -> set[str]:
        return load_confirmed_ids(self.paths.book(book_id))

    @staticmethod
    def _load_generation_report(revision_root: Path) -> dict:
        try:
            payload = json.loads((revision_root / GENERATION_REPORT_PATH).read_text(encoding="utf-8"))
            return payload if isinstance(payload, dict) else {}
        except (OSError, ValueError):
            # Revisions produced before the diagnostics report existed remain
            # reviewable; only the omission reasons are unavailable.
            return {}

    @staticmethod
    def _report_index(report: dict, key: str) -> dict[str, dict]:
        entries = report.get(key)
        if not isinstance(entries, list):
            return {}
        return {
            entry["sentence_id"]: entry
            for entry in entries
            if isinstance(entry, dict) and isinstance(entry.get("sentence_id"), str)
        }

    @staticmethod
    def _report_text(payload: dict, key: str) -> str | None:
        value = payload.get(key)
        return value if isinstance(value, str) and value else None

    @staticmethod
    def _manual_source(manual: dict[str, dict], sentence_id: str, strategy: str | None) -> str:
        action = TimelineWorkspaceService._report_text(manual.get(sentence_id, {}), "action")
        if action == "added":
            return "manual_added"
        if action == "adjusted":
            return "manual_adjusted"
        if action == "kept":
            return "asr"
        if strategy == "manual_correction":
            return "manual_adjusted"
        return "asr"
