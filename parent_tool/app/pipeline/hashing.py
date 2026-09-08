from __future__ import annotations

import hashlib
import json
import threading
from collections import OrderedDict
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


_SHA256_CACHE_LIMIT = 32
_SHA256_CACHE: OrderedDict[tuple[str, int, int], str] = OrderedDict()
_SHA256_CACHE_LOCK = threading.Lock()


def file_sha256_cached(path: Path) -> str:
    """Hash a file, reusing the previous result while its stat is unchanged.

    Meant for repeat verification of large, rarely mutated media (e.g. the
    original MP3 behind every audio Range request from the browser player).
    A changed size or mtime invalidates the entry, so a mutated file is
    re-hashed and detected exactly like before.
    """
    stat = path.stat()
    key = (str(path.resolve()), stat.st_mtime_ns, stat.st_size)
    with _SHA256_CACHE_LOCK:
        cached = _SHA256_CACHE.get(key)
        if cached is not None:
            _SHA256_CACHE.move_to_end(key)
            return cached
    value = file_sha256(path)
    with _SHA256_CACHE_LOCK:
        _SHA256_CACHE[key] = value
        while len(_SHA256_CACHE) > _SHA256_CACHE_LIMIT:
            _SHA256_CACHE.popitem(last=False)
    return value


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
