from __future__ import annotations

import html
import os
from pathlib import Path

import requests

from app.models.audio import SynthesizedAudio, VoiceConfig
from app.models.errors import PipelineError
from app.pipeline.definitions import CancellationToken


class AzureSpeechTtsProvider:
    """Azure Speech REST adapter. Credentials remain process-local environment data."""

    def __init__(
        self,
        key: str | None = None,
        region: str | None = None,
        voice_name: str | None = None,
        *,
        endpoint: str | None = None,
        timeout_seconds: float = 60,
    ) -> None:
        self._key = key if key is not None else os.environ.get("AZURE_SPEECH_KEY")
        self._region = region if region is not None else os.environ.get("AZURE_SPEECH_REGION")
        self._voice_name = voice_name or os.environ.get("AZURE_SPEECH_VOICE", "en-US-JennyNeural")
        self._endpoint = endpoint
        self._timeout_seconds = timeout_seconds

    def synthesize(
        self,
        text: str,
        voice: VoiceConfig,
        output_wav: Path,
        cancellation: CancellationToken,
    ) -> SynthesizedAudio:
        del voice  # Azure voice selection is configured by AZURE_SPEECH_VOICE.
        cancellation.raise_if_cancelled()
        if not self._key or not self._region:
            raise PipelineError(
                "AZURE_TTS_NOT_CONFIGURED",
                "尚未配置 Azure Speech；请设置 AZURE_SPEECH_KEY 和 AZURE_SPEECH_REGION。",
                status_code=422,
            )
        endpoint = self._endpoint or f"https://{self._region}.tts.speech.microsoft.com/cognitiveservices/v1"
        try:
            response = requests.post(
                endpoint,
                headers={
                    "Ocp-Apim-Subscription-Key": self._key,
                    "Content-Type": "application/ssml+xml",
                    "X-Microsoft-OutputFormat": "riff-24khz-16bit-mono-pcm",
                    "User-Agent": "ReadAlong-Parent-Tool",
                },
                data=self._ssml(text),
                timeout=self._timeout_seconds,
            )
        except requests.RequestException as exc:
            raise PipelineError(
                "AZURE_TTS_NETWORK_ERROR",
                "无法连接 Azure Speech 服务，请检查网络后重试。",
                status_code=502,
            ) from exc
        cancellation.raise_if_cancelled()
        if response.status_code in {401, 403}:
            raise PipelineError(
                "AZURE_TTS_AUTH_FAILED",
                "Azure Speech 授权失败，请检查密钥和区域配置。",
                status_code=422,
            )
        if response.status_code != 200:
            raise PipelineError(
                "AZURE_TTS_REQUEST_FAILED",
                "Azure Speech 未能生成此句音频，请稍后重试。",
                details={"status_code": response.status_code},
                status_code=502,
            )
        payload = response.content
        if len(payload) < 44 or payload[:4] != b"RIFF" or payload[8:12] != b"WAVE":
            raise PipelineError(
                "AZURE_TTS_RESPONSE_INVALID",
                "Azure Speech 返回的音频格式无效。",
                status_code=502,
            )
        output_wav.parent.mkdir(parents=True, exist_ok=True)
        temporary = output_wav.with_suffix(".part")
        try:
            temporary.write_bytes(payload)
            cancellation.raise_if_cancelled()
            temporary.replace(output_wav)
        except Exception:
            temporary.unlink(missing_ok=True)
            raise
        return SynthesizedAudio(wav_path=str(output_wav), sample_rate=24000)

    def _ssml(self, text: str) -> str:
        escaped_text = html.escape(text.strip(), quote=False)
        escaped_voice = html.escape(self._voice_name, quote=True)
        return (
            '<speak version="1.0" xml:lang="en-US">'
            f'<voice name="{escaped_voice}">{escaped_text}</voice>'
            "</speak>"
        )
