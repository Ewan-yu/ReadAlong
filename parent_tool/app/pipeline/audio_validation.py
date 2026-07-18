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
    text: str,
    timings: tuple[AudioWordTiming, ...],
    *,
    duration_seconds: float | None = None,
) -> tuple[tuple[AudioWordTiming, ...] | None, str | None]:
    expected = normalized_words(text)
    actual = tuple(word for item in timings for word in normalized_words(item.word))
    if actual != expected:
        return None, "word_sequence_mismatch"
    previous_end = 0.0
    for item in timings:
        if item.t_start < previous_end:
            return None, "word_timing_not_monotonic"
        if duration_seconds is not None and item.t_end > duration_seconds + 0.05:
            return None, "word_timing_out_of_range"
        previous_end = item.t_end
    return timings, None


def scale_word_timings(
    timings: tuple[AudioWordTiming, ...], factor: float,
) -> tuple[AudioWordTiming, ...]:
    """Move source-WAV timestamps onto the final, tempo-adjusted audio timeline."""

    return tuple(
        AudioWordTiming(
            word=item.word,
            t_start=round(item.t_start * factor, 4),
            t_end=round(item.t_end * factor, 4),
        )
        for item in timings
    )


def estimated_word_timings(text: str, duration_seconds: float) -> tuple[AudioWordTiming, ...]:
    """Provide a monotonic, weighted fallback when speech recognition cannot align a clip.

    It deliberately uses the final encoded duration so the child reader can still highlight
    each displayed word.  These timings are marked as estimated in the generation report.
    """

    words = normalized_words(text)
    if not words or duration_seconds <= 0:
        return ()
    lead_in = min(0.12, duration_seconds * 0.12)
    tail = min(0.12, duration_seconds * 0.12)
    available = max(duration_seconds - lead_in - tail, duration_seconds * 0.6)
    weight_total = sum(max(len(word), 2) for word in words)
    cursor = lead_in
    timings: list[AudioWordTiming] = []
    for index, word in enumerate(words):
        share = available * max(len(word), 2) / weight_total
        end = duration_seconds - tail if index == len(words) - 1 else cursor + share
        timings.append(
            AudioWordTiming(
                word=word,
                t_start=round(cursor, 4),
                t_end=round(max(end, cursor + 0.01), 4),
            )
        )
        cursor = end
    return tuple(timings)


def is_suspect_duration(text: str, duration_seconds: float) -> bool:
    words = normalized_words(text)
    if duration_seconds <= 0 or not words:
        return True
    seconds_per_word = duration_seconds / len(words)
    return seconds_per_word < 0.32 or seconds_per_word >= 1.5
