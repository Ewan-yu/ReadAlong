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


def test_cached_hash_reuses_result_and_detects_mutation(tmp_path: Path) -> None:
    import os

    from app.pipeline.hashing import file_sha256_cached

    target = tmp_path / "media.mp3"
    target.write_bytes(b"original-bytes")

    first = file_sha256_cached(target)
    assert first == file_sha256(target)
    assert file_sha256_cached(target) == first

    target.write_bytes(b"replaced-bytes-longer")
    assert file_sha256_cached(target) == file_sha256(target)
    assert file_sha256_cached(target) != first

    stat = target.stat()
    target.write_bytes(b"replaced-bytes-xxger")
    os.utime(target, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000))
    assert file_sha256_cached(target) == file_sha256(target)


def test_cached_hash_distinguishes_files(tmp_path: Path) -> None:
    from app.pipeline.hashing import file_sha256_cached

    left = tmp_path / "left.mp3"
    right = tmp_path / "right.mp3"
    left.write_bytes(b"left-content")
    right.write_bytes(b"right-content")

    assert file_sha256_cached(left) == file_sha256(left)
    assert file_sha256_cached(right) == file_sha256(right)
    assert file_sha256_cached(left) != file_sha256_cached(right)
