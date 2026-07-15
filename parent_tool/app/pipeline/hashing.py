from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Mapping


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def canonical_sha256(value: object) -> str:
    return hashlib.sha256(canonical_json(value)).hexdigest()


def file_sha256(path: Path, *, chunk_size: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def input_fingerprint(
    *,
    step_id: str,
    implementation_version: str,
    params_hash: str,
    source_fingerprint: str | None,
    dependencies: Mapping[str, str],
) -> str:
    return canonical_sha256(
        {
            "step_id": step_id,
            "implementation_version": implementation_version,
            "params_hash": params_hash,
            "source_fingerprint": source_fingerprint,
            "dependencies": dict(dependencies),
        }
    )
