from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest

from app.models.audio import AudioWordTiming
from app.models.errors import PipelineError
from app.models.ocr import BoundingBox, OcrPage, OcrSentence, OcrSentences, SentenceStatus
from app.models.original_timeline import (
    OriginalTimeline,
    OriginalTimelineSentence,
    OriginalTimelineSource,
    OriginalTimelineWord,
)
from app.pipeline.original_timeline import (
    load_and_validate_timeline,
    validate_timeline_timing_quality,
    validate_timeline_against_alignment_db,
    write_timeline,
)
from app.pipeline.steps.original_timeline import OriginalTimelineStep


def _sentences() -> OcrSentences:
    return OcrSentences(
        source_pages_revision="r-pages-12345678",
        params={},
        pages=(
            OcrPage(
                page_no=1,
                ocr_image="ocr/p0001.png",
                response_path="responses/p0001.json",
                blocks_seen=2,
                sentences_created=2,
            ),
        ),
        sentences=(
            OcrSentence(
                id="s0001", page_no=1, seq=1, text="Hello world.",
                bbox=BoundingBox(x=0, y=0, width=.5, height=.1), shared_bbox=False,
                status=SentenceStatus.SENTENCE,
            ),
            OcrSentence(
                id="s0002", page_no=1, seq=2, text="Good night.",
                bbox=BoundingBox(x=0, y=.2, width=.5, height=.1), shared_bbox=False,
                status=SentenceStatus.SENTENCE,
            ),
        ),
        confirmed_pages=(1,),
    )


def _timeline(*, second_text: str = "Good night.") -> OriginalTimeline:
    return OriginalTimeline(
        source=OriginalTimelineSource(
            proofread_revision="r-proofread-12345678",
            original_audio_revision="r-original-12345678",
            original_audio_sha256="a" * 64,
            vocal_sha256="b" * 64,
        ),
        sentences=(
            OriginalTimelineSentence(
                sentence_id="s0001", page_no=1, seq=1, text="Hello world.", start_ms=0,
                end_ms=800, words=(
                    OriginalTimelineWord(seq=1, text="hello", start_ms=0, end_ms=300),
                    OriginalTimelineWord(seq=2, text="world", start_ms=400, end_ms=800),
                ),
            ),
            OriginalTimelineSentence(
                sentence_id="s0002", page_no=1, seq=2, text=second_text, start_ms=1000,
                end_ms=1800, words=(
                    OriginalTimelineWord(seq=1, text="good", start_ms=1000, end_ms=1300),
                    OriginalTimelineWord(seq=2, text="night", start_ms=1400, end_ms=1800),
                ),
            ),
        ),
        audio_sha256="a" * 64,
        duration_ms=2_000,
    )


def _write_alignment(path: Path, sentences: OcrSentences, *, second_text: str = "Good night.") -> None:
    connection = sqlite3.connect(path)
    try:
        connection.execute("DROP TABLE IF EXISTS sentence")
        connection.execute("CREATE TABLE sentence (id TEXT, page_no INTEGER, seq INTEGER, text TEXT)")
        for sentence in sentences.sentences:
            text = second_text if sentence.id == "s0002" else sentence.text
            connection.execute(
                "INSERT INTO sentence VALUES (?, ?, ?, ?)",
                (sentence.id, sentence.page_no, sentence.seq, text),
            )
        connection.commit()
    finally:
        connection.close()


def test_timeline_json_is_bound_to_final_text_and_audio_hash(tmp_path: Path) -> None:
    path = tmp_path / "original_timeline.json"
    write_timeline(path, _timeline())

    loaded = load_and_validate_timeline(
        path,
        sentences=_sentences(),
        proofread_revision="r-proofread-12345678",
        original_audio_revision="r-original-12345678",
        original_audio_sha256="a" * 64,
        vocal_sha256="b" * 64,
        duration_ms=2_000,
    )

    assert loaded.sentences[0].words[0].text == "hello"
    with pytest.raises(PipelineError, match="旧校对文本或旧人声轨") as caught:
        load_and_validate_timeline(
            path,
            sentences=_sentences(),
            proofread_revision="r-proofread-12345678",
            original_audio_revision="r-original-12345678",
            original_audio_sha256="c" * 64,
            vocal_sha256="b" * 64,
            duration_ms=2_000,
        )
    assert caught.value.code == "ORIGINAL_TIMELINE_STALE"


def test_timeline_must_match_alignment_db_sentence_identity_order_and_text(tmp_path: Path) -> None:
    alignment = tmp_path / "alignment.db"
    _write_alignment(alignment, _sentences())
    validate_timeline_against_alignment_db(_timeline(), alignment)

    _write_alignment(alignment, _sentences(), second_text="Changed text.")
    with pytest.raises(PipelineError, match="点读句子索引不一致") as caught:
        validate_timeline_against_alignment_db(_timeline(), alignment)
    assert caught.value.code == "ORIGINAL_TIMELINE_ALIGNMENT_INVALID"


def test_timeline_schema_rejects_word_text_that_does_not_match_final_sentence(tmp_path: Path) -> None:
    path = tmp_path / "original_timeline.json"
    raw = _timeline().model_dump(mode="json")
    raw["sentences"][1]["words"][1]["text"] = "morning"
    path.write_text(json.dumps(raw), encoding="utf-8")

    with pytest.raises(PipelineError) as caught:
        load_and_validate_timeline(
            path,
            sentences=_sentences(),
            proofread_revision="r-proofread-12345678",
            original_audio_revision="r-original-12345678",
            original_audio_sha256="a" * 64,
            vocal_sha256="b" * 64,
            duration_ms=2_000,
        )
    assert caught.value.code == "ORIGINAL_TIMELINE_MISMATCH"


def test_builder_emits_reader_ms_contract_and_refuses_recognition_drift() -> None:
    recognized = (
        AudioWordTiming(word="Hello", t_start=0, t_end=.3),
        AudioWordTiming(word="world", t_start=.4, t_end=.8),
        AudioWordTiming(word="Good", t_start=1, t_end=1.3),
        AudioWordTiming(word="night", t_start=1.4, t_end=1.8),
    )
    timeline = OriginalTimelineStep._build_timeline(
        _sentences().sentences,
        recognized,
        proofread_revision="r-proofread-12345678",
        original_audio_revision="r-original-12345678",
        original_audio_sha256="a" * 64,
        vocal_sha256="b" * 64,
        duration_ms=2_000,
    )
    assert timeline.audio_sha256 == "a" * 64
    assert timeline.sentences[0].start_ms == 0
    assert timeline.sentences[1].words[1].end_ms == 1_800

    with pytest.raises(PipelineError) as caught:
        OriginalTimelineStep._build_timeline(
            _sentences().sentences,
            recognized[:-1],
            proofread_revision="r-proofread-12345678",
            original_audio_revision="r-original-12345678",
            original_audio_sha256="a" * 64,
            vocal_sha256="b" * 64,
            duration_ms=2_000,
        )
    assert caught.value.code == "ORIGINAL_TIMELINE_WORD_MISMATCH"


def test_timing_quality_rejects_ten_ms_words_and_multi_second_internal_gaps() -> None:
    short_word = _timeline().model_copy(
        update={
            "sentences": (
                _timeline().sentences[0].model_copy(
                    update={
                        "start_ms": 290,
                        "words": (
                            OriginalTimelineWord(seq=1, text="hello", start_ms=290, end_ms=300),
                            _timeline().sentences[0].words[1],
                        ),
                    }
                ),
                _timeline().sentences[1],
            )
        }
    )
    with pytest.raises(PipelineError) as caught:
        validate_timeline_timing_quality(short_word)
    assert caught.value.code == "ORIGINAL_TIMELINE_TIMING_UNRELIABLE"

    long_gap = _timeline().model_copy(
        update={
            "duration_ms": 5_000,
            "sentences": (
                _timeline().sentences[0].model_copy(
                    update={
                        "end_ms": 3_500,
                        "words": (
                            _timeline().sentences[0].words[0],
                            OriginalTimelineWord(seq=2, text="world", start_ms=3_300, end_ms=3_500),
                        ),
                    }
                ),
            ),
        }
    )
    with pytest.raises(PipelineError) as caught:
        validate_timeline_timing_quality(long_gap)
    assert caught.value.code == "ORIGINAL_TIMELINE_TIMING_UNRELIABLE"


def test_builder_repairs_short_forced_alignment_boundaries() -> None:
    words = OriginalTimelineStep._timeline_words(
        ("the", "frog", "family"),
        (
            ("the", AudioWordTiming(word="The", t_start=.6, t_end=.61)),
            ("frog", AudioWordTiming(word="Frog", t_start=.6, t_end=1.14)),
            ("family", AudioWordTiming(word="Family", t_start=1.14, t_end=1.94)),
        ),
        previous_end=0,
    )

    assert [(item.text, item.start_ms, item.end_ms) for item in words] == [
        ("the", 600, 630),
        ("frog", 630, 1140),
        ("family", 1140, 1940),
    ]
    validate_timeline_timing_quality(
        _timeline().model_copy(
            update={
                "sentences": (
                    _timeline().sentences[0].model_copy(
                        update={"start_ms": words[0].start_ms, "end_ms": words[-1].end_ms, "words": words}
                    ),
                )
            }
        )
    )


def test_discovery_repair_handles_short_word_after_an_overlapping_boundary() -> None:
    timings = (
        AudioWordTiming(word="before", t_start=1.0, t_end=1.1),
        AudioWordTiming(word="to", t_start=1.09, t_end=1.1),
    )

    repaired = OriginalTimelineStep._repair_short_discovery_words(timings)

    assert repaired[-1].t_start == pytest.approx(1.1)
    assert repaired[-1].t_end == pytest.approx(1.13)
    assert all(item.t_end > item.t_start for item in repaired)


def test_timeline_word_repair_keeps_tail_inside_audio_duration() -> None:
    words = OriginalTimelineStep._timeline_words(
        ("to",),
        (("to", AudioWordTiming(word="to", t_start=9.99, t_end=10.0)),),
        previous_end=0,
        duration_ms=10_000,
    )

    assert words[0].start_ms == 9_970
    assert words[0].end_ms == 10_000


def test_discovery_projection_merges_fragmented_asr_word_without_losing_boundaries() -> None:
    def timing(word: str, start: float, end: float) -> tuple[str, AudioWordTiming]:
        return word, AudioWordTiming(word=word, t_start=start, t_end=end)

    projected = OriginalTimelineStep._project_expected_phrase(
        ("my", "grandpa's", "chopsticks", "are", "long"),
        (
            timing("my", 28.9, 29.2),
            timing("grand", 29.2, 29.8),
            timing("possed", 29.8, 30.5),
            timing("chopsticks", 30.5, 31.1),
            timing("are", 31.3, 31.7),
            timing("long", 31.8, 32.4),
        ),
    )

    assert [item.word for item in projected] == ["my", "grandpa's", "chopsticks", "are", "long"]
    assert projected[1].t_start == pytest.approx(29.2)
    assert projected[1].t_end == pytest.approx(30.5)


def test_timeline_allows_a_narrated_subset_but_rejects_source_identity_drift(tmp_path: Path) -> None:
    source = _sentences()
    timeline = _timeline().model_copy(update={"sentences": (_timeline().sentences[1],)})
    path = tmp_path / "original_timeline.json"
    write_timeline(path, timeline)

    loaded = load_and_validate_timeline(
        path,
        sentences=source,
        proofread_revision="r-proofread-12345678",
        original_audio_revision="r-original-12345678",
        original_audio_sha256="a" * 64,
        vocal_sha256="b" * 64,
        duration_ms=2_000,
    )
    assert [item.sentence_id for item in loaded.sentences] == ["s0002"]

    raw = timeline.model_dump(mode="json")
    raw["sentences"][0]["text"] = "Changed text."
    path.write_text(json.dumps(raw), encoding="utf-8")
    with pytest.raises(PipelineError) as caught:
        load_and_validate_timeline(
            path,
            sentences=source,
            proofread_revision="r-proofread-12345678",
            original_audio_revision="r-original-12345678",
            original_audio_sha256="a" * 64,
            vocal_sha256="b" * 64,
            duration_ms=2_000,
        )
    assert caught.value.code == "ORIGINAL_TIMELINE_MISMATCH"


def test_discovery_selects_only_ordered_narrated_lines_and_tolerates_one_asr_typo() -> None:
    source = _sentences()
    recognized = (
        AudioWordTiming(word="Hello", t_start=0, t_end=.2),
        AudioWordTiming(word="world", t_start=.2, t_end=.4),
    )

    sentences, projected, outcomes = OriginalTimelineStep._project_discovery_timings(
        source.sentences, recognized
    )

    assert [item.id for item in sentences] == ["s0001"]
    assert [timing.word for timing in projected] == ["hello", "world"]
    assert [(item.sentence_id, item.narrated) for item in outcomes] == [
        ("s0001", True),
        ("s0002", False),
    ]
    assert outcomes[1].reason == "no_similar_match"
    assert outcomes[1].previous_matched_id == "s0001"
    assert outcomes[1].next_matched_id is None


def test_discovery_tolerates_a_fragmented_asr_word_without_changing_export_text() -> None:
    timing = AudioWordTiming(word="my", t_start=0, t_end=.1)
    actual = tuple(
        (word, timing)
        for word in ("my", "grand", "possed", "chopsticks", "are", "long")
    )
    found = OriginalTimelineStep._find_similar_phrase(
        actual,
        ("my", "grandpa's", "chopsticks", "are", "long"),
        0,
    )
    assert found == (0, 6)


def test_discovery_prefers_a_complete_phrase_over_an_earlier_partial_match() -> None:
    def timing(word: str, index: int) -> tuple[str, AudioWordTiming]:
        return word, AudioWordTiming(word=word, t_start=index, t_end=index + .2)

    actual = tuple(
        timing(word, index)
        for index, word in enumerate((
            "he", "is", "me", "however", "this", "cousin", "doesn't", "look", "like", "me",
        ))
    )

    found = OriginalTimelineStep._find_similar_phrase(
        actual,
        ("however", "this", "cousin", "doesn't", "look", "like", "me"),
        0,
    )

    assert found == (3, 7)


def test_discovery_prefers_same_length_replacement_over_a_shorter_prefix() -> None:
    def timing(word: str, index: int) -> tuple[str, AudioWordTiming]:
        return word, AudioWordTiming(word=word, t_start=index, t_end=index + 0.2)

    actual = tuple(
        timing(word, index)
        for index, word in enumerate(("right", "into", "frog's", "net"))
    )

    found = OriginalTimelineStep._find_similar_phrase(
        actual,
        ("right", "into", "frog's", "mitt"),
        0,
    )

    assert found == (0, 4)


def test_discovery_projection_keeps_sentence_when_asr_replaces_final_word() -> None:
    def timing(word: str, start: float, end: float) -> tuple[str, AudioWordTiming]:
        return word, AudioWordTiming(word=word, t_start=start, t_end=end)

    projected = OriginalTimelineStep._project_expected_phrase(
        ("right", "into", "frog's", "mitt"),
        (
            timing("right", 78.54, 78.82),
            timing("into", 78.94, 79.46),
            timing("frog's", 79.48, 80.18),
            timing("net", 80.18, 80.28),
        ),
    )

    assert [item.word for item in projected] == ["right", "into", "frog's", "mitt"]
    assert projected[-1].t_start == pytest.approx(80.18)
    assert projected[-1].t_end == pytest.approx(80.28)


def test_discovery_projection_keeps_reliable_sentences_when_one_line_is_incomplete() -> None:
    source = _sentences().model_copy(
        update={
            "sentences": (
                _sentences().sentences[0].model_copy(update={"text": "Hello little world."}),
                _sentences().sentences[1],
            )
        }
    )
    recognized = (
        AudioWordTiming(word="Hello", t_start=0, t_end=.2),
        AudioWordTiming(word="world", t_start=.2, t_end=.4),
        AudioWordTiming(word="Good", t_start=.8, t_end=1.1),
        AudioWordTiming(word="night", t_start=1.1, t_end=1.4),
    )

    sentences, projected, outcomes = OriginalTimelineStep._project_discovery_timings(
        source.sentences, recognized
    )

    assert [sentence.id for sentence in sentences] == ["s0002"]
    assert [timing.word for timing in projected] == ["good", "night"]
    assert outcomes[0].reason == "projection_failed"
    assert outcomes[0].next_matched_id == "s0002"


def test_discovery_does_not_let_a_failed_window_swallow_the_next_sentence() -> None:
    """A projection failure must leave the cursor before the failed window.

    The old pass advanced the cursor before projecting, so one unprojectable
    line also hid the sentence whose opening words that window had consumed.
    """

    source = _sentences().model_copy(
        update={
            "sentences": (
                _sentences().sentences[0].model_copy(update={"text": "Hello little world good."}),
                _sentences().sentences[1].model_copy(update={"text": "Night."}),
            )
        }
    )
    recognized = (
        AudioWordTiming(word="Hello", t_start=0, t_end=.3),
        AudioWordTiming(word="world", t_start=.3, t_end=.6),
        AudioWordTiming(word="good", t_start=.6, t_end=.9),
        AudioWordTiming(word="night", t_start=.9, t_end=1.2),
    )

    sentences, _, outcomes = OriginalTimelineStep._project_discovery_timings(
        source.sentences, recognized
    )

    assert [sentence.id for sentence in sentences] == ["s0002"]
    assert outcomes[0].narrated is False
    assert outcomes[0].reason == "projection_failed"
    assert outcomes[1].narrated is True


def test_discovery_synthesises_an_asr_dropped_middle_word_from_the_gap() -> None:
    def timing(word: str, start: float, end: float) -> tuple[str, AudioWordTiming]:
        return word, AudioWordTiming(word=word, t_start=start, t_end=end)

    projected = OriginalTimelineStep._project_expected_phrase(
        ("hello", "little", "world"),
        (timing("hello", 0, .3), timing("world", .6, .9)),
    )

    assert [item.word for item in projected] == ["hello", "little", "world"]
    assert projected[1].t_start == pytest.approx(0.3)
    assert projected[1].t_end == pytest.approx(0.6)


def test_discovery_synthesises_dropped_words_at_window_edges() -> None:
    def timing(word: str, start: float, end: float) -> tuple[str, AudioWordTiming]:
        return word, AudioWordTiming(word=word, t_start=start, t_end=end)

    trailing = OriginalTimelineStep._project_expected_phrase(
        ("the", "end"),
        (timing("the", 0, .3),),
        after_start=1.0,
    )
    assert [item.word for item in trailing] == ["the", "end"]
    assert trailing[-1].t_start == pytest.approx(0.3)

    leading = OriginalTimelineStep._project_expected_phrase(
        ("oh", "the"),
        (timing("the", .5, .8),),
        before_end=0.2,
    )
    assert [item.word for item in leading] == ["oh", "the"]
    assert leading[0].t_start == pytest.approx(0.2)
    assert leading[0].t_end == pytest.approx(0.5)


def test_discovery_accepts_two_word_line_with_one_recognised_word() -> None:
    def timing(word: str, index: int) -> tuple[str, AudioWordTiming]:
        return word, AudioWordTiming(word=word, t_start=index, t_end=index + .2)

    actual = tuple(timing(word, index) for index, word in enumerate(("frog's", "net")))

    found = OriginalTimelineStep._find_similar_phrase(actual, ("frog's", "mitt"), 0)

    assert found == (0, 2)


def test_discovery_omits_sentence_when_synthesised_gap_exceeds_reader_limit() -> None:
    """A recovered sentence must still respect the reader's 2.5 s word gap.

    The omission is per sentence: the rest of the book timeline must survive
    instead of failing the whole step at the packaging gate.
    """

    source = _sentences().model_copy(
        update={
            "sentences": (
                _sentences().sentences[0].model_copy(update={"text": "One missing three."}),
                _sentences().sentences[1],
            )
        }
    )
    recognized = (
        AudioWordTiming(word="one", t_start=0, t_end=.3),
        AudioWordTiming(word="three", t_start=4.0, t_end=4.3),
        AudioWordTiming(word="Good", t_start=5.0, t_end=5.3),
        AudioWordTiming(word="night", t_start=5.3, t_end=5.6),
    )

    sentences, _, outcomes = OriginalTimelineStep._project_discovery_timings(
        source.sentences, recognized
    )

    assert [sentence.id for sentence in sentences] == ["s0002"]
    assert outcomes[0].reason == "internal_gap_exceeded"
    assert outcomes[0].next_matched_id == "s0002"


def test_generation_report_lists_every_omission_with_reason_and_neighbours() -> None:
    source = _sentences().model_copy(
        update={
            "sentences": (
                _sentences().sentences[0],
                _sentences().sentences[1].model_copy(update={"text": "Not narrated here."}),
                _sentences().sentences[1].model_copy(update={"id": "s0003", "seq": 3, "text": "Good night."}),
            )
        }
    )
    recognized = (
        AudioWordTiming(word="Hello", t_start=0, t_end=.2),
        AudioWordTiming(word="world", t_start=.2, t_end=.4),
        AudioWordTiming(word="Good", t_start=.8, t_end=1.1),
        AudioWordTiming(word="night", t_start=1.1, t_end=1.4),
    )

    _, _, outcomes = OriginalTimelineStep._project_discovery_timings(source.sentences, recognized)
    report = OriginalTimelineStep._generation_report(
        outcomes, strategy="discovery_projection", whisper_model="tiny", recognized_word_count=4
    )

    assert report["narrated_sentence_count"] == 2
    assert report["omitted_sentence_count"] == 1
    assert report["omitted"][0]["sentence_id"] == "s0002"
    assert report["omitted"][0]["reason"] == "no_similar_match"
    assert report["omitted"][0]["previous_matched_id"] == "s0001"
    assert report["omitted"][0]["next_matched_id"] == "s0003"
