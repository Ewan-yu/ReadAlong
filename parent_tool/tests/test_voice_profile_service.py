from __future__ import annotations

from pathlib import Path

from app.models.pipeline import utc_now
from app.models.voice_profile import VoiceProfile, VoiceProfileSource, VoiceProfileStatus
from app.pipeline.hashing import file_sha256
from app.pipeline.paths import WorkspacePaths
from app.services.voice_profile_service import VoiceProfileService


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
