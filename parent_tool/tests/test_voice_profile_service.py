from __future__ import annotations

from pathlib import Path

import pytest

from app.models.errors import PipelineError
from app.models.pipeline import utc_now
from app.models.voice_profile import VoiceProfile, VoiceProfileSource, VoiceProfileStatus
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import WorkspacePaths
from app.services.voice_profile_service import VoiceProfileService


class FakeTts:
    def synthesize(self, _text, _voice, output_wav, _cancellation):
        import numpy
        import soundfile

        output_wav.parent.mkdir(parents=True, exist_ok=True)
        soundfile.write(output_wav, numpy.full(16000 * 4, 0.1), 16000)


class FakeTranscoder:
    def normalize_reference(self, source, target, _cancellation, **_kwargs):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())

    def transcode(self, source, target, _bitrate, _tempo, _cancellation):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())
        return 4.0


def _profile(root: Path) -> VoiceProfile:
    voice = root / "voices" / "v-warm-teacher"
    voice.mkdir(parents=True)
    reference = voice / "reference.wav"
    reference.write_bytes(b"fixed reference")
    now = utc_now()
    profile = VoiceProfile(
        voice_id="v-warm-teacher",
        revision=1,
        name="温暖女老师",
        source_type=VoiceProfileSource.GENERATED,
        description="warm female teacher",
        reference_sha256=file_sha256(reference),
        reference_duration_seconds=4.2,
        preview_text="Hello. Let's enjoy this story together.",
        status=VoiceProfileStatus.READY,
        is_system=True,
        is_default=True,
        created_at=now,
        updated_at=now,
    )
    (voice / "profile.json").write_text(profile.model_dump_json(), encoding="utf-8")
    return profile


def test_voice_profile_list_and_snapshot_are_fingerprint_bound(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "data")
    profile = _profile(paths.root)
    service = VoiceProfileService(paths)

    assert service.list().voices == (profile,)
    target = tmp_path / "staging" / "reference" / "voice-reference.wav"
    snapshot = service.snapshot_into(
        profile.voice_id, profile.revision, profile.reference_sha256, target
    )

    assert target.read_bytes() == b"fixed reference"
    assert snapshot.source == "profile"
    assert snapshot.voice_profile_id == profile.voice_id
    assert snapshot.reference_sha256 == profile.reference_sha256


def test_generated_voice_becomes_ready_with_actual_clone_preview(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "data")
    service = VoiceProfileService(paths, FakeTts(), FakeTranscoder())

    pending = service.begin_generated("温暖女老师", "warm female kindergarten teacher")
    service.generate(pending.voice_id)
    ready = service.get(pending.voice_id)

    assert ready.status is VoiceProfileStatus.READY
    assert ready.reference_sha256 == file_sha256(paths.root / "voices" / pending.voice_id / "reference.wav")
    assert service.preview(pending.voice_id).is_file()
    updated = service.update(pending.voice_id, name="温柔女老师", is_default=True)
    assert updated.is_default is True
    with pytest.raises(PipelineError, match="VOICE_PROFILE_DEFAULT"):
        service.delete(pending.voice_id)


def test_default_update_keeps_the_existing_name(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path / "data")
    profile = _profile(paths.root)
    service = VoiceProfileService(paths)

    updated = service.update(profile.voice_id, name=None, is_default=True)

    assert updated.name == "温暖女老师"
    assert service.get(profile.voice_id).name == "温暖女老师"
