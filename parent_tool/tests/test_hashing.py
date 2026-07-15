from pathlib import Path

from app.pipeline.hashing import canonical_sha256, file_sha256, input_fingerprint


def test_canonical_hash_ignores_mapping_order() -> None:
    assert canonical_sha256({"b": 2, "a": 1}) == canonical_sha256({"a": 1, "b": 2})


def test_canonical_hash_changes_for_semantic_values() -> None:
    baseline = canonical_sha256({"quality": 82, "split": True, "pages": [1, 2]})

    assert canonical_sha256({"quality": 78, "split": True, "pages": [1, 2]}) != baseline
    assert canonical_sha256({"quality": 82, "split": False, "pages": [1, 2]}) != baseline
    assert canonical_sha256({"quality": 82, "split": True, "pages": [2, 1]}) != baseline


def test_file_sha256_tracks_contents(tmp_path: Path) -> None:
    source = tmp_path / "source.pdf"
    source.write_bytes(b"first")
    first_hash = file_sha256(source)

    source.write_bytes(b"second")

    assert file_sha256(source) != first_hash


def test_input_fingerprint_tracks_all_inputs() -> None:
    baseline = input_fingerprint(
        step_id="ocr",
        implementation_version="v1",
        params_hash="params-a",
        source_fingerprint=None,
        dependencies={"pages": "pages-a"},
    )

    variants = (
        {"step_id": "audio"},
        {"implementation_version": "v2"},
        {"params_hash": "params-b"},
        {"source_fingerprint": "source-a"},
        {"dependencies": {"pages": "pages-b"}},
    )
    base_kwargs = {
        "step_id": "ocr",
        "implementation_version": "v1",
        "params_hash": "params-a",
        "source_fingerprint": None,
        "dependencies": {"pages": "pages-a"},
    }

    for changes in variants:
        assert input_fingerprint(**(base_kwargs | changes)) != baseline
