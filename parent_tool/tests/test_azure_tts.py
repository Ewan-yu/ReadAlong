from __future__ import annotations

from pathlib import Path

import pytest

from app.models.audio import AudioParams, SynthesizedAudio, TtsProviderKind, VoiceConfig
from app.models.errors import PipelineError
from app.pipeline.definitions import CancellationToken
from app.pipeline.steps.audio import AudioStep
from app.providers.tts.azure import AzureSpeechTtsProvider


class _Response:
    def __init__(self, status_code: int, content: bytes) -> None:
        self.status_code = status_code
        self.content = content


def _wav() -> bytes:
    return b"RIFF" + b"\x00" * 4 + b"WAVE" + b"\x00" * 32


def test_azure_tts_posts_escaped_ssml_and_writes_wav(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    def fake_post(url: str, **kwargs: object) -> _Response:
        captured["url"] = url
        captured.update(kwargs)
        return _Response(200, _wav())

    monkeypatch.setattr("app.providers.tts.azure.requests.post", fake_post)
    output = tmp_path / "audio.wav"
    result = AzureSpeechTtsProvider(
        key="test-key",
        region="eastus",
        voice_name="en-US-JennyNeural",
    ).synthesize("Fish & chips", VoiceConfig(), output, CancellationToken())

    assert result == SynthesizedAudio(wav_path=str(output), sample_rate=24000)
    assert output.read_bytes() == _wav()
    assert captured["url"] == "https://eastus.tts.speech.microsoft.com/cognitiveservices/v1"
    assert captured["headers"] == {
        "Ocp-Apim-Subscription-Key": "test-key",
        "Content-Type": "application/ssml+xml",
        "X-Microsoft-OutputFormat": "riff-24khz-16bit-mono-pcm",
        "User-Agent": "ReadAlong-Parent-Tool",
    }
    assert "Fish &amp; chips" in str(captured["data"])


def test_azure_tts_rejects_missing_configuration_without_exposing_key(tmp_path: Path) -> None:
    with pytest.raises(PipelineError) as raised:
        AzureSpeechTtsProvider(key="do-not-leak", region=None).synthesize(
            "Hello", VoiceConfig(), tmp_path / "audio.wav", CancellationToken()
        )

    assert raised.value.code == "AZURE_TTS_NOT_CONFIGURED"
    assert "do-not-leak" not in str(raised.value)


def test_azure_tts_cancellation_removes_partial_wav(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    cancellation = CancellationToken()

    def fake_post(_url: str, **_kwargs: object) -> _Response:
        cancellation.request()
        return _Response(200, _wav())

    monkeypatch.setattr("app.providers.tts.azure.requests.post", fake_post)
    output = tmp_path / "audio.wav"
    with pytest.raises(PipelineError, match="JOB_CANCELLED"):
        AzureSpeechTtsProvider(key="test-key", region="eastus").synthesize(
            "Hello", VoiceConfig(), output, cancellation
        )

    assert not output.exists()
    assert not output.with_suffix(".part").exists()


def test_audio_step_falls_back_to_azure_and_allows_per_sentence_override(tmp_path: Path) -> None:
    primary = _RecordingTts(error=PipelineError("TTS_SYNTHESIS_FAILED", "primary failed"))
    azure = _RecordingTts()
    step = AudioStep(primary, _UnusedAligner(), _UnusedTranscoder(), azure_tts=azure)

    output = tmp_path / "audio.wav"
    generated, provider = step._synthesize(
        "Hello",
        VoiceConfig(),
        output,
        CancellationToken(),
        primary_provider=TtsProviderKind.VOXCPM,
        fallback_provider=TtsProviderKind.AZURE,
    )

    assert provider is TtsProviderKind.AZURE
    assert generated.sample_rate == 24000
    assert primary.calls == 1
    assert azure.calls == 1
    assert AudioParams(azure_sentence_ids=("s0001",)).azure_sentence_ids == ("s0001",)
    with pytest.raises(ValueError, match="duplicates"):
        AudioParams(azure_sentence_ids=("s0001", "s0001"))


def test_audio_step_can_fall_back_when_requested_azure_is_unavailable(tmp_path: Path) -> None:
    voxcpm = _RecordingTts()
    step = AudioStep(voxcpm, _UnusedAligner(), _UnusedTranscoder())

    generated, provider = step._synthesize(
        "Hello",
        VoiceConfig(),
        tmp_path / "fallback.wav",
        CancellationToken(),
        primary_provider=TtsProviderKind.AZURE,
        fallback_provider=TtsProviderKind.VOXCPM,
    )

    assert provider is TtsProviderKind.VOXCPM
    assert generated.sample_rate == 24000
    assert voxcpm.calls == 1


class _RecordingTts:
    def __init__(self, error: PipelineError | None = None) -> None:
        self.calls = 0
        self._error = error

    def synthesize(self, _text, _voice, output_wav, _cancellation) -> SynthesizedAudio:
        self.calls += 1
        if self._error is not None:
            raise self._error
        output_wav.write_bytes(_wav())
        return SynthesizedAudio(wav_path=str(output_wav), sample_rate=24000)


class _UnusedAligner:
    def align(self, *_args):
        raise AssertionError("aligner is not used by this unit test")


class _UnusedTranscoder:
    def transcode(self, *_args):
        raise AssertionError("transcoder is not used by this unit test")
