from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Iterable

REVIEW_FILE_NAME = "timeline_review.json"
REVIEW_SCHEMA_VERSION = 1


def review_path(workspace_dir: Path) -> Path:
    return workspace_dir / REVIEW_FILE_NAME


def load_confirmed_ids(workspace_dir: Path) -> set[str]:
    """Parent-confirmed set of sentences the narration intentionally skips.

    The store is workspace-level (not a step revision): it survives lyric
    regenerations so a word-list page does not re-surface as suspicious after
    every ASR retry.  A missing or corrupt file reads as empty.
    """

    try:
        payload = json.loads(review_path(workspace_dir).read_text(encoding="utf-8"))
        ids = payload["confirmed_not_narrated"]
        if not isinstance(ids, list):
            return set()
        return {item for item in ids if isinstance(item, str)}
    except (OSError, ValueError, KeyError, TypeError):
        return set()


def replace_confirmed_ids(workspace_dir: Path, ids: Iterable[str]) -> tuple[str, ...]:
    confirmed = tuple(sorted(set(ids)))
    _write_review(workspace_dir, confirmed)
    return confirmed


def union_confirmed_ids(workspace_dir: Path, ids: Iterable[str]) -> tuple[str, ...]:
    confirmed = tuple(sorted(load_confirmed_ids(workspace_dir) | set(ids)))
    _write_review(workspace_dir, confirmed)
    return confirmed


def _write_review(workspace_dir: Path, confirmed: tuple[str, ...]) -> None:
    target = review_path(workspace_dir)
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": REVIEW_SCHEMA_VERSION,
        "confirmed_not_narrated": list(confirmed),
    }
    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=target.parent, prefix=".timeline-review-", delete=False
    )
    try:
        with handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
        os.replace(handle.name, target)
    except BaseException:
        Path(handle.name).unlink(missing_ok=True)
        raise
