from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Protocol

from app.models.errors import PipelineError
from app.models.original_audio import OriginalAudioParams
from app.models.pipeline import StepId, StepResult
from app.pipeline.definitions import StepRunContext
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import ensure_within
from app.providers.separation import SeparationOutput


class SeparationProvider(Protocol):
    def separate(self, source: Path, output: Path, *, model_name: str, cancellation: object, progress: object) -> SeparationOutput: ...


class OriginalAudioStep:
    step_id = StepId.ORIGINAL_AUDIO
    implementation_version = "original-audio-v1"
    params_model = OriginalAudioParams

    def __init__(self, provider: SeparationProvider) -> None:
        self._provider = provider

    def run(self, context: StepRunContext, params: OriginalAudioParams) -> StepResult:
        path, expected = context.source_original_audio_path, context.source_original_audio_sha256
        if not path or not expected:
            raise PipelineError("ORIGINAL_AUDIO_NOT_UPLOADED", "尚未上传原音音频，不能执行人声分离。", status_code=409)
        source = ensure_within(context.workspace_dir, context.workspace_dir / Path(path))
        if not source.is_file() or source.stat().st_size <= 0:
            raise PipelineError("ORIGINAL_AUDIO_MISSING", "原音音频不存在或为空。", status_code=409)
        actual = file_sha256(source)
        if actual != expected:
            raise PipelineError("ORIGINAL_AUDIO_HASH_MISMATCH", "原音音频已被修改，请重新导入。", status_code=409)
        separated = self._provider.separate(source, context.staging_dir, model_name=params.model, cancellation=context.cancellation, progress=context.progress)
        background = context.staging_dir / "background.ogg"
        vocals = context.staging_dir / "preview" / "vocals.ogg"
        if separated.background_ogg != background:
            background.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(separated.background_ogg, background)
        if separated.vocals_ogg != vocals:
            vocals.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(separated.vocals_ogg, vocals)
        report = {**separated.report, "source_path": "original/source.mp3", "source_sha256": actual, "source_proofread_revision": context.dependency_outputs[StepId.PROOFREAD].name, "background": {"path": "background.ogg", "sha256": file_sha256(background), "duration_ms": separated.duration_ms}, "vocals_preview": {"path": "preview/vocals.ogg", "sha256": file_sha256(vocals)}}
        (context.staging_dir / "source_report.json").write_text(json.dumps({"source_sha256": actual, "source_size_bytes": source.stat().st_size}, ensure_ascii=False), encoding="utf-8")
        (context.staging_dir / "separation_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        outputs = ["background.ogg", "preview/vocals.ogg", "preview/background.ogg", "source_report.json", "separation_report.json"]
        outputs.extend(f"waveform/{name}.json" for name in ("original", "vocals", "background"))
        return StepResult(outputs=tuple(outputs), summary=report)
