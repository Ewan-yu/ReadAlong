from __future__ import annotations

from pathlib import Path
from threading import Lock
from typing import Protocol

from app.models.audio import AudioWordTiming
from app.models.errors import PipelineError
from app.pipeline.definitions import CancellationToken


class WordAligner(Protocol):
    def align(
        self, wav_path: Path, language: str, cancellation: CancellationToken
    ) -> tuple[AudioWordTiming, ...]: ...


class StableTsWordAligner:
    """stable-ts wrapper that only loads Whisper when an audio job actually requests it."""

    def __init__(self, model_name: str = "tiny") -> None:
        self._model_name = model_name
        self._model: object | None = None
        self._lock = Lock()

    def align(
        self, wav_path: Path, language: str, cancellation: CancellationToken
    ) -> tuple[AudioWordTiming, ...]:
        cancellation.raise_if_cancelled()
        try:
            result = self._load_model().transcribe(str(wav_path), language=language)
            cancellation.raise_if_cancelled()
            timings = tuple(
                AudioWordTiming(word=word.word.strip(), t_start=float(word.start), t_end=float(word.end))
                for segment in result.segments
                for word in (getattr(segment, "words", None) or ())
                if word.word.strip()
            )
            if not timings:
                raise PipelineError(
                    "WORD_ALIGNMENT_EMPTY",
                    "未能从此句音频得到词级时间，将以整句字幕降级。",
                    status_code=422,
                )
            return timings
        except PipelineError:
            raise
        except Exception as exc:
            raise PipelineError(
                "WORD_ALIGNMENT_FAILED",
                "词级对齐失败，将以整句字幕降级。",
                status_code=422,
            ) from exc

    def _load_model(self):
        with self._lock:
            if self._model is None:
                try:
                    import stable_whisper

                    self._model = stable_whisper.load_model(self._model_name)
                except Exception as exc:
                    raise PipelineError(
                        "WORD_ALIGNMENT_MODEL_LOAD_FAILED",
                        "stable-ts 模型无法加载，请检查 GPU、网络和依赖。",
                        status_code=500,
                    ) from exc
            return self._model
