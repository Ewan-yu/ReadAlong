from __future__ import annotations

import os
from pathlib import Path
import sys
from concurrent.futures import ThreadPoolExecutor
from threading import Lock
from typing import Protocol

from app.models.audio import AudioWordTiming
from app.models.errors import PipelineError
from app.pipeline.definitions import CancellationToken, wait_for_future


class WordAligner(Protocol):
    def align(
        self, wav_path: Path, language: str, cancellation: CancellationToken
    ) -> tuple[AudioWordTiming, ...]: ...

    def align_script(
        self,
        wav_path: Path,
        text: str,
        language: str,
        cancellation: CancellationToken,
    ) -> tuple[AudioWordTiming, ...]: ...


class StableTsWordAligner:
    """stable-ts wrapper that only loads Whisper when an audio job actually requests it."""

    def __init__(self, model_name: str = "tiny") -> None:
        self._model_name = model_name
        self._model: object | None = None
        self._lock = Lock()
        self._inference_executor = ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix="readalong-stable-ts",
        )

    def align(
        self, wav_path: Path, language: str, cancellation: CancellationToken
    ) -> tuple[AudioWordTiming, ...]:
        cancellation.raise_if_cancelled()
        try:
            self._ensure_ffmpeg_on_path()
            future = self._inference_executor.submit(
                self._load_model().transcribe,
                str(wav_path),
                language=language,
            )
            result = wait_for_future(future, cancellation)
            cancellation.raise_if_cancelled()
            timings = self._timings_from_result(result)
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

    def align_script(
        self,
        wav_path: Path,
        text: str,
        language: str,
        cancellation: CancellationToken,
    ) -> tuple[AudioWordTiming, ...]:
        """Force-align an already confirmed narration script.

        Free transcription is useful only to discover which proofread lines are
        actually narrated.  The exported lyric words must instead come from the
        proofread script, otherwise an ASR spelling guess can leak into a book
        package and make the reader reject it.
        """
        cancellation.raise_if_cancelled()
        try:
            self._ensure_ffmpeg_on_path()
            future = self._inference_executor.submit(
                self._load_model().align,
                str(wav_path),
                text,
                language=language,
            )
            result = wait_for_future(future, cancellation)
            cancellation.raise_if_cancelled()
            timings = self._timings_from_result(result)
            if not timings:
                raise PipelineError(
                    "WORD_ALIGNMENT_EMPTY",
                    "未能将原音与朗读脚本对齐，请检查原音内容。",
                    status_code=422,
                )
            return timings
        except PipelineError:
            raise
        except Exception as exc:
            raise PipelineError(
                "WORD_ALIGNMENT_FAILED",
                "原音朗读脚本对齐失败，请确认分离的人声轨清晰可听。",
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

    @staticmethod
    def _timings_from_result(result: object) -> tuple[AudioWordTiming, ...]:
        """Normalise zero-width stable-ts boundaries before later validation."""
        timings: list[AudioWordTiming] = []
        for segment in getattr(result, "segments", ()):
            for word in getattr(segment, "words", None) or ():
                text = word.word.strip()
                if not text:
                    continue
                start = float(word.start)
                end = float(word.end)
                # Export still verifies every word and all final millisecond
                # ranges; this only prevents a one-frame ASR boundary from
                # aborting narration discovery before forced alignment.
                timings.append(
                    AudioWordTiming(word=text, t_start=start, t_end=max(end, start + .01))
                )
        return tuple(timings)

    @staticmethod
    def _ensure_ffmpeg_on_path() -> None:
        conda_bin = Path(sys.prefix) / "Library" / "bin"
        if (conda_bin / "ffmpeg.exe").is_file():
            existing = os.environ.get("PATH", "").split(os.pathsep)
            if str(conda_bin) not in existing:
                os.environ["PATH"] = str(conda_bin) + os.pathsep + os.environ.get("PATH", "")
