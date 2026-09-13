from pathlib import Path

import pytest

from app.models.errors import PipelineError
from app.models.pipeline import StepId, StepSuccess, utc_now
from app.pipeline.artifacts import ArtifactStore
from app.pipeline.paths import WorkspacePaths


def test_manifest_is_sorted_and_fingerprinted(tmp_path: Path) -> None:
    store = ArtifactStore(WorkspacePaths(tmp_path))
    staging = store.create_staging("book-1", "12345678-1234-4234-8234-123456789abc")
    (staging / "b.txt").write_text("b", encoding="utf-8")
    (staging / "a.txt").write_text("a", encoding="utf-8")

    manifest, fingerprint = store.build_manifest(staging, ("b.txt", "a.txt"))

    assert [item.path for item in manifest] == ["a.txt", "b.txt"]
    assert len(fingerprint) == 64


@pytest.mark.parametrize("outputs", [(), ("a.txt", "a.txt"), ("../outside.txt",)])
def test_manifest_rejects_invalid_outputs(tmp_path: Path, outputs: tuple[str, ...]) -> None:
    store = ArtifactStore(WorkspacePaths(tmp_path))
    staging = store.create_staging("book-1", "12345678-1234-4234-8234-123456789abc")
    (staging / "a.txt").write_text("a", encoding="utf-8")

    with pytest.raises(PipelineError) as caught:
        store.build_manifest(staging, outputs)

    assert caught.value.code == "OUTPUT_VALIDATION_FAILED"


def test_publish_moves_staging_to_new_revision(tmp_path: Path) -> None:
    paths = WorkspacePaths(tmp_path)
    store = ArtifactStore(paths)
    staging = store.create_staging("book-1", "12345678-1234-4234-8234-123456789abc")
    (staging / "result.json").write_text("{}", encoding="utf-8")

    output_root = store.publish(
        "book-1", StepId.PAGES, "r-abc12345-12345678", staging
    )

    assert output_root == "01_pages/revisions/r-abc12345-12345678"
    assert (tmp_path / "book-1" / output_root / "result.json").is_file()
    assert not staging.exists()


def _published_candidate(store: ArtifactStore) -> StepSuccess:
    staging = store.create_staging("book-1", "22345678-1234-4234-8234-123456789abc")
    (staging / "background.ogg").write_bytes(b"background-track")
    (staging / "preview").mkdir()
    (staging / "preview" / "vocals.ogg").write_bytes(b"vocals-track")
    manifest, fingerprint = store.build_manifest(
        staging, ("background.ogg", "preview/vocals.ogg")
    )
    output_root = store.publish_candidate(
        "book-1", StepId.ORIGINAL_AUDIO, "r-cand1234-12345678", staging
    )
    return StepSuccess(
        revision_id="r-cand1234-12345678",
        output_root=output_root,
        params_hash="a" * 64,
        input_fingerprint="b" * 64,
        output_fingerprint=fingerprint,
        outputs=manifest,
        completed_at=utc_now(),
    )


def test_promote_candidate_is_idempotent(tmp_path: Path) -> None:
    store = ArtifactStore(WorkspacePaths(tmp_path))
    success = _published_candidate(store)

    published = store.promote_candidate("book-1", success.revision_id, success)
    # 确认请求重放:完整 revision 已存在时直接成功,不再报候选损坏。
    replayed = store.promote_candidate("book-1", success.revision_id, success)

    assert replayed == published
    target = tmp_path / "book-1" / published.output_root
    assert (target / "background.ogg").is_file()
    assert list(target.parent.glob(".*promote*")) == []


def test_promote_candidate_recovers_from_interrupted_leftover(tmp_path: Path) -> None:
    store = ArtifactStore(WorkspacePaths(tmp_path))
    success = _published_candidate(store)
    published = store.promote_candidate("book-1", success.revision_id, success)
    target = tmp_path / "book-1" / published.output_root
    # 模拟上一轮 promote 被杀留下的半拷贝正式目录。
    (target / "background.ogg").unlink()

    recovered = store.promote_candidate("book-1", success.revision_id, success)

    assert recovered == published
    assert store.verify("book-1", StepId.ORIGINAL_AUDIO, recovered) is True
    assert list(target.parent.glob(".*promote*")) == []
