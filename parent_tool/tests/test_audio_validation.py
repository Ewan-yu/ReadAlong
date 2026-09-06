import pytest

from app.models.audio import AudioWordTiming
from app.pipeline.audio_validation import (
    estimated_word_timings,
    is_suspect_duration,
    normalized_words,
    repair_word_timings,
    scale_word_timings,
    validate_word_timings,
)


def test_word_normalization_matches_punctuation_case_and_unicode_quotes() -> None:
    assert normalized_words("I’m READY, aren't I?") == ("i'm", "ready", "aren't", "i")


def test_word_timing_validation_accepts_matching_monotonic_words() -> None:
    timings = (
        AudioWordTiming(word="Hello", t_start=0, t_end=0.2),
        AudioWordTiming(word="world!", t_start=0.25, t_end=0.6),
    )

    accepted, reason = validate_word_timings("hello, world!", timings)

    assert accepted == timings
    assert reason is None


def test_word_timing_validation_rejects_word_mismatch_and_overlap() -> None:
    mismatch, mismatch_reason = validate_word_timings(
        "Hello there.", (AudioWordTiming(word="Hello", t_start=0, t_end=0.2),)
    )
    overlap, overlap_reason = validate_word_timings(
        "Hello there.",
        (
            AudioWordTiming(word="Hello", t_start=0, t_end=0.3),
            AudioWordTiming(word="there", t_start=0.2, t_end=0.5),
        ),
    )

    assert mismatch is None
    assert mismatch_reason == "word_sequence_mismatch"
    assert overlap is None
    assert overlap_reason == "word_timing_not_monotonic"


def test_duration_suspect_boundaries() -> None:
    assert is_suspect_duration("One two", 0.1) is True
    assert is_suspect_duration("One two", 3) is True
    assert is_suspect_duration("One two", 0.8) is False


def test_estimated_word_timings_cover_each_word_in_final_audio_duration() -> None:
    timings = estimated_word_timings("My family.", 1.2)

    assert tuple(item.word for item in timings) == ("my", "family")
    assert timings[0].t_start >= 0
    assert timings[0].t_end <= timings[1].t_start
    assert timings[-1].t_end <= 1.2


def test_scaled_word_timings_follow_tempo_adjusted_audio() -> None:
    source = (AudioWordTiming(word="hello", t_start=0.3, t_end=0.6),)

    assert scale_word_timings(source, 1 / 0.75) == (
        AudioWordTiming(word="hello", t_start=0.4, t_end=0.8),
    )


def test_repair_word_timings_handles_overlaps_and_short_boundaries() -> None:
    source = (
        AudioWordTiming(word="before", t_start=1.0, t_end=1.1),
        AudioWordTiming(word="to", t_start=1.09, t_end=1.1),
        AudioWordTiming(word="after", t_start=1.1, t_end=1.3),
    )

    repaired = repair_word_timings(source, minimum_duration_seconds=0.03)

    assert [item.word for item in repaired] == ["before", "to", "after"]
    assert repaired[0].t_start == pytest.approx(1.0)
    assert repaired[0].t_end == pytest.approx(1.1)
    assert repaired[1].t_start == pytest.approx(1.1)
    assert repaired[1].t_end == pytest.approx(1.13)
    assert repaired[2].t_start == pytest.approx(1.13)
    assert repaired[2].t_end == pytest.approx(1.3)
