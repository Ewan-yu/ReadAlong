from pathlib import Path

import pytest

from app.models.errors import PipelineError
from app.models.pipeline import StepId
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
