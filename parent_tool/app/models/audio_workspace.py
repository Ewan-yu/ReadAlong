from __future__ import annotations

from app.models.audio import AudioParams, AudioSentenceReport
from app.models.ocr import OcrSentence
from app.models.pipeline import FrozenModel


class AudioWorkspaceSentence(FrozenModel):
    sentence: OcrSentence
    report: AudioSentenceReport | None = None


class AudioWorkspaceResponse(FrozenModel):
    proofread_revision_id: str
    audio_revision_id: str | None = None
    params: AudioParams
    original_audio_path: str | None = None
    sentences: tuple[AudioWorkspaceSentence, ...]
