from __future__ import annotations

import re
import unicodedata

from app.models.audio import AudioWordTiming


_WORDS = re.compile(r"[a-z0-9]+(?:['-][a-z0-9]+)*")


def normalized_words(text: str) -> tuple[str, ...]:
    """The one comparison representation shared by sentence text and stable-ts words."""

    normalized = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    return tuple(_WORDS.findall(normalized))


def validate_word_timings(
    text: str, timings: tuple[AudioWordTiming, ...]
) -> tuple[tuple[AudioWordTiming, ...] | None, str | None]:
    expected = normalized_words(text)
    actual = tuple(word for item in timings for word in normalized_words(item.word))
    if actual != expected:
        return None, "word_sequence_mismatch"
    previous_end = 0.0
    for item in timings:
        if item.t_start < previous_end:
            return None, "word_timing_not_monotonic"
        previous_end = item.t_end
    return timings, None


def is_suspect_duration(text: str, duration_seconds: float) -> bool:
    words = normalized_words(text)
    if duration_seconds <= 0 or not words:
        return True
    seconds_per_word = duration_seconds / len(words)
    return seconds_per_word < 0.08 or seconds_per_word > 1.2
