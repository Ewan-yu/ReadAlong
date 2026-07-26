from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from app.models.audio import AudioWordTiming
from app.models.errors import PipelineError
from app.models.ocr import OcrSentences
from app.models.original_timeline import OriginalTimeline
from app.pipeline.audio_validation import validate_word_timings
from app.pipeline.hashing import file_sha256


TIMELINE_PATH = "timeline/original_timeline.json"
MINIMUM_WORD_DURATION_MS = 30
MAXIMUM_INTERNAL_WORD_GAP_MS = 2_500


def validate_timeline_timing_quality(timeline: OriginalTimeline) -> None:
    """Reject structurally valid but perceptually unusable forced alignment.

    Stable-ts can occasionally collapse a repeated first word to its 10 ms
    normalization floor or attach a later repeated word several seconds away.
    Such JSON is monotonic, but sentence clipping will cut speech or borrow the
    previous sentence on Android.  Packaging must fail instead of publishing it.
    """

    for sentence in timeline.sentences:
        previous_end: int | None = None
        for word in sentence.words:
            if word.end_ms - word.start_ms < MINIMUM_WORD_DURATION_MS:
                raise PipelineError(
                    "ORIGINAL_TIMELINE_TIMING_UNRELIABLE",
                    "原音逐词时间过短，无法可靠切分逐句示范音，请重新生成原音字幕。",
                    details={"sentence_id": sentence.sentence_id, "word": word.text},
                    status_code=422,
                )
            if previous_end is not None and word.start_ms - previous_end > MAXIMUM_INTERNAL_WORD_GAP_MS:
                raise PipelineError(
                    "ORIGINAL_TIMELINE_TIMING_UNRELIABLE",
                    "原音句内词间隔异常，无法可靠切分逐句示范音，请重新生成原音字幕。",
                    details={"sentence_id": sentence.sentence_id, "word": word.text},
                    status_code=422,
                )
            previous_end = word.end_ms


def load_and_validate_timeline(
    path: Path,
    *,
    sentences: OcrSentences,
    proofread_revision: str,
    original_audio_revision: str,
    original_audio_sha256: str,
    duration_ms: int,
    vocal_sha256: str,
) -> OriginalTimeline:
    """Load an immutable timeline and prove it still belongs to these inputs."""

    try:
        timeline = OriginalTimeline.model_validate_json(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise PipelineError(
            "ORIGINAL_TIMELINE_INVALID",
            "原音逐词时间线已损坏，请重新生成。",
            status_code=409,
        ) from exc
    source = timeline.source
    if (
        source.proofread_revision != proofread_revision
        or source.original_audio_revision != original_audio_revision
        or source.original_audio_sha256 != original_audio_sha256
        or source.vocal_sha256 != vocal_sha256
        or timeline.audio_sha256 != original_audio_sha256
        or timeline.duration_ms != duration_ms
    ):
        raise PipelineError(
            "ORIGINAL_TIMELINE_STALE",
            "原音逐词时间线基于旧校对文本或旧人声轨，请重新生成。",
            status_code=409,
        )
    validate_timeline_timing_quality(timeline)
    source_by_id = {sentence.id: sentence for sentence in sentences.sentences}
    for actual in timeline.sentences:
        expected = source_by_id.get(actual.sentence_id)
        if expected is None:
            raise PipelineError("ORIGINAL_TIMELINE_MISMATCH", "原音字幕引用了不存在的绘本句子。", status_code=409)
        if (
            actual.sentence_id != expected.id
            or actual.page_no != expected.page_no
            or actual.seq != expected.seq
            or actual.text != expected.text
        ):
            raise PipelineError("ORIGINAL_TIMELINE_MISMATCH", "原音字幕与校对文本不一致。", status_code=409)
        timings, reason = validate_word_timings(
            expected.text,
            tuple(
                AudioWordTiming(
                    word=word.text, t_start=word.start_ms / 1000, t_end=word.end_ms / 1000
                )
                for word in actual.words
            ),
        )
        if timings is None:
            raise PipelineError(
                "ORIGINAL_TIMELINE_MISMATCH",
                "原音字幕词序与校对文本不一致。",
                details={"sentence_id": expected.id, "reason": reason},
                status_code=409,
            )
    return timeline


def validate_timeline_against_alignment_db(
    timeline: OriginalTimeline,
    alignment_db: Path,
) -> None:
    """The exported reader data has one authoritative sentence identity table.

    Timeline words must never be accepted if their IDs, order or displayed text
    drift from ``alignment.db``.  The audio hash is compared before this call via
    ``load_and_validate_timeline`` against manifest.original_audio.sha256.
    """

    try:
        connection = sqlite3.connect(alignment_db)
        rows = connection.execute(
            "SELECT id, page_no, seq, text FROM sentence ORDER BY seq"
        ).fetchall()
    except sqlite3.Error as exc:
        raise PipelineError("ORIGINAL_TIMELINE_ALIGNMENT_INVALID", "点读句子索引无法校验。", status_code=500) from exc
    finally:
        try:
            connection.close()
        except UnboundLocalError:
            pass
    indexed = {row[0]: row for row in rows}
    expected = [(item.sentence_id, item.page_no, item.seq, item.text) for item in timeline.sentences]
    if any(indexed.get(item[0]) != item for item in expected):
        raise PipelineError(
            "ORIGINAL_TIMELINE_ALIGNMENT_INVALID",
            "原音字幕与点读句子索引不一致，不能导出。",
            status_code=409,
        )


def timeline_manifest_entry(timeline_path: Path, timeline: OriginalTimeline) -> dict:
    return {
        "timeline_path": TIMELINE_PATH,
        "timeline_sha256": file_sha256(timeline_path),
        "timeline_sentence_count": len(timeline.sentences),
        "vocal_sha256": timeline.source.vocal_sha256,
    }


def write_timeline(path: Path, timeline: OriginalTimeline) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(timeline.model_dump(mode="json"), ensure_ascii=False, indent=2), encoding="utf-8")
