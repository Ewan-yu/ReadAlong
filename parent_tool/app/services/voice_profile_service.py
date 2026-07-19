from __future__ import annotations

import os
import shutil
import json
from pathlib import Path
from threading import Lock
from uuid import uuid4

from pydantic import ValidationError

from app.models.audio import VoiceConfig, VoiceMode, VoiceSnapshot
from app.models.errors import PipelineError
from app.models.pipeline import utc_now
from app.models.voice_profile import (
    VoiceProfile,
    VoiceProfileListResponse,
    VoiceProfileSource,
    VoiceProfileStatus,
)
from app.pipeline.definitions import CancellationToken
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import WorkspacePaths, ensure_within
from app.providers.tts import FfmpegOpusTranscoder, TtsProvider


_PREVIEW_TEXT = "Hello. Let's enjoy this story together."
_ANCHOR_TEXT = "Hello. I am your reading teacher. Let's enjoy this story together."


class VoiceProfileService:
    """Persistent voice profiles plus immutable snapshots for audio revisions."""

    def __init__(
        self,
        paths: WorkspacePaths,
        tts: TtsProvider | None = None,
        transcoder: FfmpegOpusTranscoder | None = None,
    ) -> None:
        self.paths = paths
        self._tts = tts
        self._transcoder = transcoder
        self._lock = Lock()

    @property
    def root(self) -> Path:
        return self.paths.root / "voices"

    def list(self) -> VoiceProfileListResponse:
        if not self.root.is_dir():
            return VoiceProfileListResponse(voices=())
        profiles = [profile for candidate in self.root.iterdir() if (profile := self._read(candidate))]
        return VoiceProfileListResponse(
            voices=tuple(sorted(profiles, key=lambda item: (not item.is_default, item.name.casefold())))
        )

    def get(self, voice_id: str) -> VoiceProfile:
        return self._load(voice_id)

    def begin_generated(self, name: str, description: str) -> VoiceProfile:
        profile = self._create_profile(name, VoiceProfileSource.GENERATED, description=description)
        return profile

    def begin_uploaded(self, name: str, source: Path) -> VoiceProfile:
        profile = self._create_profile(name, VoiceProfileSource.UPLOADED)
        target = self._directory(profile.voice_id) / "source.bin"
        try:
            shutil.move(str(source), target)
        except OSError as exc:
            self._set_failed(profile.voice_id, "无法保存上传的声音文件。")
            raise PipelineError("VOICE_UPLOAD_SAVE_FAILED", "无法保存上传的声音文件。", status_code=500) from exc
        return profile

    def generate(self, voice_id: str) -> None:
        """Run the durable generation task after its HTTP request has returned."""
        profile = self._load(voice_id)
        if profile.source_type is not VoiceProfileSource.GENERATED:
            raise PipelineError("VOICE_SOURCE_MISMATCH", "此声音不是系统生成声音。", status_code=409)
        if not profile.description:
            raise PipelineError("VOICE_DESCRIPTION_MISSING", "系统生成声音缺少音色描述。", status_code=409)
        self._require_runtime()
        directory = self._directory(voice_id)
        raw_reference = directory / ".generated-reference.wav"
        try:
            self._update(profile, progress_message="正在生成固定参考声…", failure_message=None)
            self._tts.synthesize(
                _ANCHOR_TEXT,
                VoiceConfig(mode=VoiceMode.DESIGN, description=profile.description),
                raw_reference,
                CancellationToken(),
            )
            self._finalize_reference(profile, raw_reference)
        except PipelineError as exc:
            self._set_failed(voice_id, exc.message)
        except Exception:
            self._set_failed(voice_id, "声音样本生成失败，请检查模型、GPU 与 ffmpeg 后重试。")
        finally:
            raw_reference.unlink(missing_ok=True)

    def prepare_upload(self, voice_id: str, *, start_seconds: float, duration_seconds: float) -> None:
        profile = self._load(voice_id)
        if profile.source_type is not VoiceProfileSource.UPLOADED:
            raise PipelineError("VOICE_SOURCE_MISMATCH", "此声音不是上传的克隆样本。", status_code=409)
        self._require_runtime()
        source = self._directory(voice_id) / "source.bin"
        if not source.is_file():
            self._set_failed(voice_id, "上传的声音文件不存在。")
            return
        normalized = self._directory(voice_id) / ".uploaded-reference.wav"
        try:
            self._update(profile, progress_message="正在标准化并检查上传的声音…", failure_message=None)
            self._transcoder.normalize_reference(
                source,
                normalized,
                CancellationToken(),
                start_seconds=start_seconds,
                max_seconds=int(duration_seconds),
            )
            self._finalize_reference(profile, normalized)
        except PipelineError as exc:
            self._set_failed(voice_id, exc.message)
        except Exception:
            self._set_failed(voice_id, "无法处理上传的声音，请使用清晰的 MP3 或 WAV 重新上传。")
        finally:
            normalized.unlink(missing_ok=True)

    def regenerate_preview(self, voice_id: str) -> None:
        profile = self._load(voice_id)
        if profile.status is not VoiceProfileStatus.READY:
            raise PipelineError("VOICE_PROFILE_NOT_READY", "声音样本尚未准备完成。", status_code=409)
        self._require_runtime()
        try:
            self._update(profile, status=VoiceProfileStatus.PROCESSING, progress_message="正在重新生成试听…")
            self._generate_preview(self._load(voice_id))
        except PipelineError as exc:
            self._set_failed(voice_id, exc.message)
        except Exception:
            self._set_failed(voice_id, "试听生成失败，请检查模型、GPU 与 ffmpeg 后重试。")

    def update(self, voice_id: str, *, name: str | None, is_default: bool | None) -> VoiceProfile:
        profile = self._load(voice_id)
        if is_default and profile.status is not VoiceProfileStatus.READY:
            raise PipelineError("VOICE_PROFILE_NOT_READY", "只有可试听的声音样本才能设为默认。", status_code=409)
        if is_default:
            for item in self.list().voices:
                if item.voice_id != voice_id and item.is_default:
                    self._update(item, is_default=False)
        changes: dict[str, object] = {}
        if name is not None:
            changes["name"] = name.strip()
        if is_default is not None:
            changes["is_default"] = is_default
        return self._update(profile, **changes)

    def delete(self, voice_id: str) -> None:
        profile = self._load(voice_id)
        if profile.is_system:
            raise PipelineError("VOICE_PROFILE_SYSTEM", "系统声音样本不能删除。", status_code=409)
        if profile.is_default:
            raise PipelineError("VOICE_PROFILE_DEFAULT", "请先将另一个声音样本设为默认，再删除此样本。", status_code=409)
        directory = self._directory(voice_id)
        try:
            shutil.rmtree(directory)
        except OSError as exc:
            raise PipelineError("VOICE_PROFILE_DELETE_FAILED", "删除声音样本失败。", status_code=500) from exc

    def snapshot_into(
        self, voice_id: str, revision: int, fingerprint: str, destination: Path
    ) -> VoiceSnapshot:
        profile = self._load(voice_id)
        if profile.status is not VoiceProfileStatus.READY:
            raise PipelineError("VOICE_PROFILE_NOT_READY", "所选声音样本尚未准备完成。", status_code=409)
        if profile.revision != revision or profile.reference_sha256 != fingerprint:
            raise PipelineError(
                "VOICE_PROFILE_CHANGED", "所选声音样本已经更新，请刷新页面后重新选择。", status_code=409
            )
        reference = self.reference(voice_id)
        actual = file_sha256(reference)
        if actual != profile.reference_sha256:
            raise PipelineError("VOICE_PROFILE_CORRUPT", "声音样本文件已损坏，请重新创建。", status_code=409)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(reference, destination)
        return VoiceSnapshot(
            source="profile",
            name=profile.name,
            reference_path="reference/voice-reference.wav",
            reference_sha256=actual,
            voice_profile_id=profile.voice_id,
            voice_profile_revision=profile.revision,
        )

    def preview(self, voice_id: str) -> Path:
        profile = self._load(voice_id)
        preview = ensure_within(self.root, self._directory(voice_id) / "preview.ogg")
        if profile.status is not VoiceProfileStatus.READY or not preview.is_file():
            raise PipelineError("VOICE_PREVIEW_NOT_FOUND", "该声音样本还没有可试听的预览。", status_code=404)
        return preview

    def reference(self, voice_id: str) -> Path:
        reference = ensure_within(self.root, self._directory(voice_id) / "reference.wav")
        if not reference.is_file():
            raise PipelineError("VOICE_PROFILE_CORRUPT", "声音样本文件已损坏，请重新创建。", status_code=409)
        return reference

    def _create_profile(
        self, name: str, source_type: VoiceProfileSource, *, description: str | None = None
    ) -> VoiceProfile:
        voice_id = f"v-{uuid4().hex}"
        now = utc_now()
        profile = VoiceProfile(
            voice_id=voice_id,
            revision=1,
            name=name.strip(),
            source_type=source_type,
            description=description,
            preview_text=_PREVIEW_TEXT,
            status=VoiceProfileStatus.PROCESSING,
            progress_message="等待开始处理…",
            warnings=(
                "上传音频中的音乐、混响或多人说话会影响克隆效果；请先试听实际合成结果。",
            ) if source_type is VoiceProfileSource.UPLOADED else (),
            created_at=now,
            updated_at=now,
        )
        self._directory(voice_id).mkdir(parents=True, exist_ok=False)
        self._write(profile)
        return profile

    def _finalize_reference(self, profile: VoiceProfile, temporary_reference: Path) -> None:
        reference = self._directory(profile.voice_id) / "reference.wav"
        self._transcoder.normalize_reference(temporary_reference, reference, CancellationToken(), max_seconds=15)
        duration, warnings = self._validate_reference(reference, profile.source_type)
        ready = self._update(
            self._load(profile.voice_id),
            reference_sha256=file_sha256(reference),
            reference_duration_seconds=duration,
            warnings=warnings,
            progress_message="正在生成实际克隆试听…",
        )
        self._generate_preview(ready)

    def _generate_preview(self, profile: VoiceProfile) -> None:
        directory = self._directory(profile.voice_id)
        preview_wav = directory / ".preview.wav"
        preview_ogg = directory / "preview.ogg"
        try:
            self._tts.synthesize(
                profile.preview_text,
                VoiceConfig(mode=VoiceMode.CLONE, reference_wav_path=str(directory / "reference.wav")),
                preview_wav,
                CancellationToken(),
            )
            self._transcoder.transcode(preview_wav, preview_ogg, 32, 0.9, CancellationToken())
            self._update(
                self._load(profile.voice_id),
                status=VoiceProfileStatus.READY,
                progress_message=None,
                failure_message=None,
            )
        finally:
            preview_wav.unlink(missing_ok=True)

    @staticmethod
    def _validate_reference(path: Path, source_type: VoiceProfileSource) -> tuple[float, tuple[str, ...]]:
        try:
            import numpy
            import soundfile

            samples, sample_rate = soundfile.read(path, always_2d=True)
        except Exception as exc:
            raise PipelineError("VOICE_REFERENCE_INVALID", "声音参考文件无法读取。", status_code=422) from exc
        duration = len(samples) / sample_rate
        peak = float(numpy.max(numpy.abs(samples))) if len(samples) else 0.0
        rms = float(numpy.sqrt(numpy.mean(numpy.square(samples)))) if len(samples) else 0.0
        clipped_ratio = float(numpy.mean(numpy.abs(samples) >= 0.99)) if len(samples) else 1.0
        if duration < 3 or peak < 0.015 or rms < 0.003:
            raise PipelineError("VOICE_REFERENCE_TOO_SHORT_OR_QUIET", "声音样本过短或过安静，请使用 3–15 秒清晰人声。", status_code=422)
        if clipped_ratio > 0.01:
            raise PipelineError("VOICE_REFERENCE_CLIPPED", "声音样本存在明显削波，请更换录音后重试。", status_code=422)
        warnings: tuple[str, ...] = ()
        if source_type is VoiceProfileSource.UPLOADED:
            warnings = ("上传音频中的音乐、混响或多人说话会影响克隆效果；请先试听实际合成结果。",)
        return round(duration, 3), warnings

    def _set_failed(self, voice_id: str, message: str) -> None:
        try:
            self._update(
                self._load(voice_id),
                status=VoiceProfileStatus.FAILED,
                progress_message=None,
                failure_message=message[:500],
            )
        except PipelineError:
            return

    def _update(self, profile: VoiceProfile, **changes: object) -> VoiceProfile:
        with self._lock:
            current = self._load(profile.voice_id)
            payload = current.model_dump()
            payload.update(changes)
            payload["updated_at"] = utc_now()
            updated = VoiceProfile.model_validate(payload)
            self._write(updated)
            return updated

    def _write(self, profile: VoiceProfile) -> None:
        target = self._directory(profile.voice_id) / "profile.json"
        temporary = target.with_name(f".{target.name}.{uuid4().hex}.tmp")
        try:
            temporary.write_text(profile.model_dump_json(indent=2), encoding="utf-8")
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)

    def _directory(self, voice_id: str) -> Path:
        if not voice_id.startswith("v-"):
            raise PipelineError("VOICE_PROFILE_NOT_FOUND", "没有找到该声音样本。", status_code=404)
        return ensure_within(self.root, self.root / voice_id)

    def _load(self, voice_id: str) -> VoiceProfile:
        profile = self._read(self._directory(voice_id))
        if profile is None or profile.voice_id != voice_id:
            raise PipelineError("VOICE_PROFILE_NOT_FOUND", "没有找到该声音样本。", status_code=404)
        return profile

    def _require_runtime(self) -> None:
        if self._tts is None or self._transcoder is None:
            raise PipelineError("VOICE_PROFILE_UNAVAILABLE", "声音样本服务尚未准备完成。", status_code=409)

    def _read(self, directory: Path) -> VoiceProfile | None:
        if not directory.is_dir() or directory.is_symlink():
            return None
        try:
            raw = json.loads((directory / "profile.json").read_text(encoding="utf-8"))
            # M3.7.1 repair: the first default-switch request wrote an omitted
            # name as null. The generated WAV is valid, so recover it rather
            # than making an otherwise usable voice disappear from the library.
            if not isinstance(raw.get("name"), str) or not raw["name"].strip():
                raw["name"] = "未命名声音样本"
                profile = VoiceProfile.model_validate(raw)
                self._write(profile)
                return profile
            return VoiceProfile.model_validate(raw)
        except (OSError, ValidationError, ValueError, TypeError, json.JSONDecodeError):
            return None
