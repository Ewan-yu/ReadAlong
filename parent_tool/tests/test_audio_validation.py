from app.models.audio import AudioWordTiming
from app.pipeline.audio_validation import is_suspect_duration, normalized_words, validate_word_timings


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
