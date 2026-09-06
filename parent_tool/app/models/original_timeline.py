from __future__ import annotations

from typing import Literal

from pydantic import Field, model_validator

from app.models.pipeline import FrozenModel


class ManualTimelineSentence(FrozenModel):
    """A parent-marked sentence boundary; text identity stays bound to proofread."""

    sentence_id: str = Field(pattern=r"^s[0-9]{4,}$")
    start_ms: int = Field(ge=0)
    end_ms: int = Field(gt=0)

    @model_validator(mode="after")
    def has_positive_span(self) -> "ManualTimelineSentence":
        if self.end_ms <= self.start_ms:
            raise ValueError("manual sentence must have a positive time span")
        return self


class OriginalTimelineParams(FrozenModel):
    """Controls for the opt-in whole-book vocal alignment job."""

    language: str = Field(default="en", pattern=r"^[a-z]{2,8}$")
    # ``tiny`` keeps the default fast; ``base``/``small`` buy recognition
    # quality for long or noisy narrations at the cost of inference time.
    whisper_model: Literal["tiny", "base", "small"] = "tiny"
    # Non-empty switches the step to manual correction mode: the full,
    # parent-reviewed sentence table replaces a fresh ASR discovery pass.
    manual_sentences: tuple[ManualTimelineSentence, ...] = ()

    @model_validator(mode="after")
    def validates_manual_table(self) -> "OriginalTimelineParams":
        if not self.manual_sentences:
            return self
        identifiers = [item.sentence_id for item in self.manual_sentences]
        if len(set(identifiers)) != len(identifiers):
            raise ValueError("manual sentence identifiers must be unique")
        starts = [item.start_ms for item in self.manual_sentences]
        if starts != sorted(starts) or len(set(starts)) != len(starts):
            raise ValueError("manual sentences must be ordered by start time without overlap")
        return self


class OriginalTimelineWord(FrozenModel):
    seq: int = Field(ge=1)
    text: str = Field(min_length=1)
    start_ms: int = Field(ge=0)
    end_ms: int = Field(gt=0)

    @model_validator(mode="after")
    def has_positive_duration(self) -> "OriginalTimelineWord":
        if self.end_ms <= self.start_ms:
            raise ValueError("timeline word must have positive duration")
        return self


class OriginalTimelineSentence(FrozenModel):
    sentence_id: str = Field(pattern=r"^s[0-9]{4,}$")
    page_no: int = Field(ge=1)
    seq: int = Field(ge=1)
    text: str = Field(min_length=1)
    start_ms: int = Field(ge=0)
    end_ms: int = Field(gt=0)
    words: tuple[OriginalTimelineWord, ...] = Field(min_length=1)

    @model_validator(mode="after")
    def has_matching_bounds(self) -> "OriginalTimelineSentence":
        if self.end_ms <= self.start_ms:
            raise ValueError("timeline sentence must have positive duration")
        if self.words[0].start_ms != self.start_ms or self.words[-1].end_ms != self.end_ms:
            raise ValueError("timeline sentence bounds must match first and last word")
        if [word.seq for word in self.words] != list(range(1, len(self.words) + 1)):
            raise ValueError("timeline word sequence must be continuous")
        return self


class OriginalTimelineSource(FrozenModel):
    proofread_revision: str = Field(pattern=r"^r-[a-z0-9-]{8,80}$")
    original_audio_revision: str = Field(pattern=r"^r-[a-z0-9-]{8,80}$")
    original_audio_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    vocal_path: str = "preview/vocals.ogg"
    vocal_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")


class OriginalTimeline(FrozenModel):
    schema_version: int = 1
    source: OriginalTimelineSource
    audio_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    duration_ms: int = Field(gt=0)
    sentences: tuple[OriginalTimelineSentence, ...] = Field(min_length=1)

    @model_validator(mode="after")
    def has_continuous_sentences(self) -> "OriginalTimeline":
        # Original narration can intentionally omit cover, copyright or word
        # list text. `seq` remains the source sentence sequence, so it only
        # needs to be unique and increasing within this lyric script.
        if not self.sentences:
            raise ValueError("timeline must contain at least one narrated sentence")
        if len({item.sentence_id for item in self.sentences}) != len(self.sentences):
            raise ValueError("timeline sentence identifiers must be unique")
        previous_end = 0
        previous_seq = 0
        for sentence in self.sentences:
            if sentence.seq <= previous_seq or sentence.start_ms < previous_end or sentence.end_ms > self.duration_ms:
                raise ValueError("timeline sentence timings must be monotonic")
            previous_end = sentence.end_ms
            previous_seq = sentence.seq
        return self
