from __future__ import annotations

from app.models.audio import AudioParams, AudioSentenceReport, VoiceSnapshot
from app.models.ocr import OcrSentence
from app.models.pipeline import FrozenModel


class AudioWorkspaceSentence(FrozenModel):
    sentence: OcrSentence
    report: AudioSentenceReport | None = None


class AudioWorkspaceResponse(FrozenModel):
    proofread_revision_id: str
    audio_revision_id: str | None = None
    params: AudioParams
    voice_snapshot: VoiceSnapshot | None = None
    original_audio_path: str | None = None
    sentences: tuple[AudioWorkspaceSentence, ...]
