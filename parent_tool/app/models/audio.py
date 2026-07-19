from __future__ import annotations

from enum import Enum
from typing import Literal

from pydantic import ConfigDict, Field, model_validator

from app.models.pipeline import FrozenModel


class VoiceMode(str, Enum):
    DESIGN = "design"
    CLONE = "clone"


class TtsProviderKind(str, Enum):
    VOXCPM = "voxcpm"


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
    # 历史 audio revision 曾写入 Azure 字段；读取时忽略这些已下线字段，
    # 这样旧工作区仍可打开并可用本地 VoxCPM 重新生成。
    model_config = ConfigDict(frozen=True, extra="ignore")

    voice: VoiceConfig = Field(default_factory=VoiceConfig)
    voice_profile_id: str | None = Field(default=None, pattern=r"^v-[a-z0-9-]{3,80}$")
    voice_profile_revision: int | None = Field(default=None, ge=1)
    voice_fingerprint: str | None = Field(default=None, pattern=r"^[0-9a-f]{64}$")
    opus_bitrate_kbps: int = Field(default=32, ge=16, le=128)
    tempo: float = Field(default=0.9, ge=0.75, le=1.25)
    language: str = Field(default="en", pattern=r"^[a-z]{2,8}$")
    sentence_ids: tuple[str, ...] = ()
    base_audio_revision: str | None = Field(default=None, pattern=r"^r-[a-z0-9-]{8,80}$")

    @model_validator(mode="after")
    def validates_regeneration(self) -> "AudioParams":
        if len(set(self.sentence_ids)) != len(self.sentence_ids):
            raise ValueError("sentence_ids must not contain duplicates")
        if self.sentence_ids and not self.base_audio_revision:
            raise ValueError("partial audio regeneration requires base_audio_revision")
        if self.base_audio_revision and not self.sentence_ids:
            raise ValueError("base_audio_revision is only valid for partial regeneration")
        profile_parts = (self.voice_profile_id, self.voice_profile_revision, self.voice_fingerprint)
        if any(part is not None for part in profile_parts) and any(part is None for part in profile_parts):
            raise ValueError("voice profile id, revision, and fingerprint must be provided together")
        return self


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
    provider: TtsProviderKind | None = None
    suspect_tts: bool = False
    error_code: str | None = None


class VoiceSnapshot(FrozenModel):
    """The exact voice reference preserved with one audio revision."""

    source: Literal["legacy", "profile"] = "legacy"
    name: str = Field(min_length=1, max_length=200)
    reference_path: str = Field(pattern=r"^reference/voice-reference\.wav$")
    reference_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    voice_profile_id: str | None = Field(default=None, pattern=r"^v-[a-z0-9-]{3,80}$")
    voice_profile_revision: int | None = Field(default=None, ge=1)


class AudioGenerationReport(FrozenModel):
    schema_version: int = 1
    source_proofread_revision: str = Field(min_length=1)
    params: AudioParams
    sentences: tuple[AudioSentenceReport, ...]
    voice_snapshot: VoiceSnapshot | None = None
