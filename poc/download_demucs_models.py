from __future__ import annotations

import argparse
import hashlib
import os
import time
from pathlib import Path, PurePosixPath

import requests


DEFAULT_BASE_URL = "https://dl.fbaipublicfiles.com/demucs/"
MODEL_FILES = {
    "htdemucs": ("hybrid_transformer/955717e8-8726e21a.th",),
    "htdemucs_ft": (
        "hybrid_transformer/f7e0c4bc-ba3fe64a.th",
        "hybrid_transformer/d12395a8-e57c48e6.th",
        "hybrid_transformer/92cfc3b6-ef3bcb9c.th",
        "hybrid_transformer/04573f0d-f3cf25b2.th",
    ),
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _expected_hash(filename: str) -> str:
    return Path(filename).stem.rsplit("-", 1)[1]


def _is_valid(path: Path, *, model_filename: str | None = None) -> bool:
    filename = model_filename or path.name
    return path.is_file() and _sha256(path).startswith(_expected_hash(filename))


def _download(
    session: requests.Session,
    url: str,
    target: Path,
    *,
    attempts: int,
) -> None:
    if _is_valid(target):
        print(f"[cached] {target.name} ({target.stat().st_size / 1024 / 1024:.1f} MB)")
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(target.suffix + ".part")
    if _is_valid(partial, model_filename=target.name):
        os.replace(partial, target)
        print(f"[ready] {target.name} ({target.stat().st_size / 1024 / 1024:.1f} MB)")
        return
    for attempt in range(1, attempts + 1):
        offset = partial.stat().st_size if partial.is_file() else 0
        headers = {"Range": f"bytes={offset}-"} if offset else {}
        try:
            with session.get(
                url,
                headers=headers,
                stream=True,
                timeout=(20, 120),
            ) as response:
                response.raise_for_status()
                append = offset > 0 and response.status_code == 206
                if offset and not append:
                    offset = 0
                total = response.headers.get("Content-Length")
                expected_total = offset + int(total) if total else None
                mode = "ab" if append else "wb"
                with partial.open(mode) as output:
                    downloaded = offset
                    for chunk in response.iter_content(chunk_size=1024 * 1024):
                        if not chunk:
                            continue
                        output.write(chunk)
                        downloaded += len(chunk)
                        if expected_total:
                            print(
                                f"\r[download] {target.name} "
                                f"{downloaded / 1024 / 1024:.1f}/"
                                f"{expected_total / 1024 / 1024:.1f} MB",
                                end="",
                                flush=True,
                            )
                print()
            if not _is_valid(partial, model_filename=target.name):
                raise RuntimeError("downloaded file SHA-256 does not match its model filename")
            os.replace(partial, target)
            print(f"[ready] {target.name} ({target.stat().st_size / 1024 / 1024:.1f} MB)")
            return
        except (OSError, requests.RequestException, RuntimeError) as exc:
            if attempt >= attempts:
                raise RuntimeError(f"failed to download {url}: {exc}") from exc
            delay = min(20, 2**attempt)
            print(f"[retry {attempt}/{attempts}] {target.name}: {exc}; {delay}s later")
            time.sleep(delay)


def main() -> None:
    parser = argparse.ArgumentParser(description="可续传下载并校验 Demucs PoC 权重。")
    parser.add_argument(
        "--models",
        nargs="+",
        choices=tuple(MODEL_FILES),
        default=list(MODEL_FILES),
    )
    parser.add_argument(
        "--cache",
        type=Path,
        required=True,
        help="TORCH_HOME 根目录；权重写入 <cache>/hub/checkpoints。",
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("DEMUCS_MODEL_BASE_URL", DEFAULT_BASE_URL),
        help="可替换为国内镜像根地址，需保留 hybrid_transformer/ 路径。",
    )
    parser.add_argument("--attempts", type=int, default=5)
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/") + "/"
    checkpoints = args.cache.expanduser().resolve() / "hub" / "checkpoints"
    session = requests.Session()
    session.headers["User-Agent"] = "ReadAlong-Demucs-PoC/0.1"
    seen: set[str] = set()
    for model in args.models:
        for relative in MODEL_FILES[model]:
            if relative in seen:
                continue
            seen.add(relative)
            filename = PurePosixPath(relative).name
            _download(
                session,
                base_url + relative,
                checkpoints / filename,
                attempts=max(1, args.attempts),
            )


if __name__ == "__main__":
    main()
