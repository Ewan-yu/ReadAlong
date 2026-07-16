from __future__ import annotations

from enum import Enum

from pydantic import Field, model_validator

from app.models.pipeline import FrozenModel


class VoiceMode(str, Enum):
    DESIGN = "design"
    CLONE = "clone"


class VoiceConfig(FrozenModel):
    mode: VoiceMode = VoiceMode.DESIGN
    description: str = Field(
        default="warm female kindergarten teacher, slow and clear", min_length=3, max_length=500
    )
    reference_wav_path: str | None = None

    @model_validator(mode="after")
    def validates_reference(self) -> "VoiceConfig":
        if self.mode is VoiceMode.CLONE and not self.reference_wav_path:
            raise ValueError("clone voice mode requires reference_wav_path")
        return self


class AudioParams(FrozenModel):
    voice: VoiceConfig = Field(default_factory=VoiceConfig)
    opus_bitrate_kbps: int = Field(default=32, ge=16, le=128)
    language: str = Field(default="en", pattern=r"^[a-z]{2,8}$")


class AudioWordTiming(FrozenModel):
    word: str = Field(min_length=1)
    t_start: float = Field(ge=0)
    t_end: float = Field(gt=0)

    @model_validator(mode="after")
    def has_positive_duration(self) -> "AudioWordTiming":
        if self.t_end <= self.t_start:
            raise ValueError("word timing must have positive duration")
        return self


class SynthesizedAudio(FrozenModel):
    wav_path: str = Field(min_length=1)
    sample_rate: int = Field(gt=0)


class AudioSentenceReport(FrozenModel):
    sentence_id: str = Field(pattern=r"^s[0-9]{4,}$")
    audio_path: str | None = None
    duration_seconds: float | None = Field(default=None, gt=0)
    word_timing: tuple[AudioWordTiming, ...] | None = None
    suspect_tts: bool = False
    error_code: str | None = None


class AudioGenerationReport(FrozenModel):
    schema_version: int = 1
    source_proofread_revision: str = Field(min_length=1)
    params: AudioParams
    sentences: tuple[AudioSentenceReport, ...]
