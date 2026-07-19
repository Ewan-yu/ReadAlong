from __future__ import annotations

from pathlib import Path

from pydantic import ValidationError

from app.models.audio import VoiceSnapshot
from app.models.errors import PipelineError
from app.models.voice_profile import VoiceProfile, VoiceProfileListResponse, VoiceProfileStatus
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import WorkspacePaths, ensure_within


class VoiceProfileService:
    """Read-only Voice Profile registry and immutable audio snapshot resolver."""

    def __init__(self, paths: WorkspacePaths) -> None:
        self.paths = paths

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

    def snapshot_into(
        self,
        voice_id: str,
        revision: int,
        fingerprint: str,
        destination: Path,
    ) -> VoiceSnapshot:
        profile = self._load(voice_id)
        if profile.status is not VoiceProfileStatus.READY:
            raise PipelineError("VOICE_PROFILE_NOT_READY", "所选声音样本尚未准备完成。", status_code=409)
        if profile.revision != revision or profile.reference_sha256 != fingerprint:
            raise PipelineError(
                "VOICE_PROFILE_CHANGED",
                "所选声音样本已经更新，请刷新页面后重新选择。",
                status_code=409,
            )
        reference = self.reference(voice_id)
        actual = file_sha256(reference)
        if actual != profile.reference_sha256:
            raise PipelineError("VOICE_PROFILE_CORRUPT", "声音样本文件已损坏，请重新创建。", status_code=409)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(reference.read_bytes())
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
        preview = ensure_within(self.root, self.root / voice_id / "preview.ogg")
        if profile.status is not VoiceProfileStatus.READY or not preview.is_file():
            raise PipelineError("VOICE_PREVIEW_NOT_FOUND", "该声音样本还没有可试听的预览。", status_code=404)
        return preview

    def reference(self, voice_id: str) -> Path:
        return ensure_within(self.root, self.root / voice_id / "reference.wav")

    def _load(self, voice_id: str) -> VoiceProfile:
        if not voice_id.startswith("v-"):
            raise PipelineError("VOICE_PROFILE_NOT_FOUND", "没有找到该声音样本。", status_code=404)
        profile = self._read(self.root / voice_id)
        if profile is None or profile.voice_id != voice_id:
            raise PipelineError("VOICE_PROFILE_NOT_FOUND", "没有找到该声音样本。", status_code=404)
        return profile

    @staticmethod
    def _read(directory: Path) -> VoiceProfile | None:
        if not directory.is_dir() or directory.is_symlink():
            return None
        try:
            return VoiceProfile.model_validate_json((directory / "profile.json").read_text(encoding="utf-8"))
        except (OSError, ValidationError, ValueError):
            return None
