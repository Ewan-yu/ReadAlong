# -*- coding: utf-8 -*-
"""
ReadAlong — OCR 验证（PaddleOCR-VL-1.6）
=========================================
目的：
1. 验证 PaddleOCR-VL-1.6 目前是否可调用
2. 落盘原始 JSONL，确认返回结构
3. 提取可用于点读的文本/坐标候选，判断是否需要继续使用 PP-OCRv6

用法：
    python poc/ocr_vl_validate.py --token <TOKEN>
    python poc/ocr_vl_validate.py --token <TOKEN> --file path/to/file.pdf
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

import requests

JOB_URL = "https://paddleocr.aistudio-app.com/api/v2/ocr/jobs"
MODEL = "PaddleOCR-VL-1.6"
SRC_DIR = Path(__file__).parent / "TestSource"
OUT_DIR = Path(__file__).parent / "out"
OUT_DIR.mkdir(exist_ok=True)
RETRY_STATUS_CODES = {401, 429, 500, 502, 503, 504}
MIN_SUBMIT_INTERVAL_SECONDS = 0.6
_last_submit_at = 0.0

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def choose_default_file() -> Path:
    candidates = (
        sorted(SRC_DIR.glob("*.pdf"))
        + sorted(SRC_DIR.glob("*.png"))
        + sorted(SRC_DIR.glob("*.jpg"))
        + sorted(SRC_DIR.glob("*.jpeg"))
    )
    if not candidates:
        raise FileNotFoundError(f"{SRC_DIR} 下没有可用 PDF/图片")
    return candidates[0]


def choose_latest_jsonl() -> Path:
    candidates = sorted(OUT_DIR.glob("ocr_vl*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not candidates:
        raise FileNotFoundError(f"{OUT_DIR} 下没有 OCR JSONL")
    return candidates[0]


def request_with_retry(method: str, url: str, *, max_attempts: int = 5, base_delay: float = 2.0, **kwargs) -> requests.Response:
    for attempt in range(max_attempts):
        try:
            resp = requests.request(method, url, **kwargs)
        except requests.RequestException:
            if attempt == max_attempts - 1:
                raise
            time.sleep(base_delay * (2 ** attempt))
            continue

        if resp.status_code not in RETRY_STATUS_CODES or attempt == max_attempts - 1:
            return resp

        retry_after = resp.headers.get("Retry-After")
        delay = float(retry_after) if retry_after and retry_after.isdigit() else base_delay * (2 ** attempt)
        print(f"请求返回 {resp.status_code}，{delay:.1f}s 后重试...")
        time.sleep(delay)
    raise RuntimeError("请求重试失败")


def throttle_submit() -> None:
    global _last_submit_at
    elapsed = time.time() - _last_submit_at
    if elapsed < MIN_SUBMIT_INTERVAL_SECONDS:
        time.sleep(MIN_SUBMIT_INTERVAL_SECONDS - elapsed)
    _last_submit_at = time.time()


def submit_job(token: str, file_path: Path) -> str:
    headers = {"Authorization": f"bearer {token}"}
    optional_payload = {
        "useDocOrientationClassify": False,
        "useDocUnwarping": False,
        "useChartRecognition": False,
    }
    data = {
        "model": MODEL,
        "optionalPayload": json.dumps(optional_payload, ensure_ascii=False),
    }
    throttle_submit()
    with file_path.open("rb") as f:
        resp = request_with_retry("post", JOB_URL, headers=headers, data=data, files={"file": f}, timeout=180)
    if resp.status_code != 200:
        raise RuntimeError(f"提交失败 {resp.status_code}: {resp.text[:500]}")
    payload = resp.json()
    return payload["data"]["jobId"]


def poll_job(token: str, job_id: str) -> dict[str, Any]:
    headers = {"Authorization": f"bearer {token}"}
    while True:
        resp = request_with_retry("get", f"{JOB_URL}/{job_id}", headers=headers, timeout=30)
        if resp.status_code != 200:
            raise RuntimeError(f"轮询失败 {resp.status_code}: {resp.text[:300]}")
        payload = resp.json()["data"]
        state = payload["state"]
        if state == "pending":
            print("状态: pending")
        elif state == "running":
            progress = payload.get("extractProgress", {})
            total_pages = progress.get("totalPages")
            extracted_pages = progress.get("extractedPages")
            if total_pages is None:
                print("状态: running")
            else:
                print(f"状态: running ({extracted_pages}/{total_pages})")
        elif state == "done":
            print("状态: done")
            return payload
        elif state == "failed":
            raise RuntimeError(f"任务失败: {payload.get('errorMsg')}")
        else:
            print(f"状态: {state}")
        time.sleep(5)


def fetch_jsonl(jsonl_url: str, stem: str) -> list[dict[str, Any]]:
    resp = request_with_retry("get", jsonl_url, timeout=120)
    resp.raise_for_status()
    raw_text = resp.text
    raw_path = OUT_DIR / f"{stem}.jsonl"
    raw_path.write_text(raw_text, encoding="utf-8")
    print(f"原始 JSONL 已保存: {raw_path}")
    records = []
    for line in raw_text.splitlines():
        line = line.strip()
        if not line:
            continue
        records.append(json.loads(line))
    return records


def load_jsonl_file(path: Path) -> list[dict[str, Any]]:
    records = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        records.append(json.loads(line))
    return records


def save_sample_json(obj: Any, path: Path) -> None:
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"样例 JSON 已保存: {path}")


def iter_dicts(node: Any):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from iter_dicts(value)
    elif isinstance(node, list):
        for item in node:
            yield from iter_dicts(item)


def looks_like_bbox(value: Any) -> bool:
    if not isinstance(value, list) or len(value) != 4:
        return False
    return all(isinstance(x, (int, float)) for x in value)


def looks_like_poly(value: Any) -> bool:
    if not isinstance(value, list) or len(value) < 4:
        return False
    return all(isinstance(p, list) and len(p) == 2 for p in value)


def poly_to_bbox(poly: list[list[float]]) -> list[float]:
    xs = [p[0] for p in poly]
    ys = [p[1] for p in poly]
    return [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]


def collect_text_candidates(record: dict[str, Any]) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    seen: set[tuple[str, str | None]] = set()
    for item in iter_dicts(record):
        text = None
        for key in ("text", "rec_text", "content", "markdown_text", "block_content"):
            value = item.get(key)
            if isinstance(value, str) and value.strip():
                text = value.strip()
                break
        if not text:
            continue

        bbox = None
        for key in ("bbox", "box", "rect", "block_bbox", "coordinate"):
            value = item.get(key)
            if looks_like_bbox(value):
                bbox = value
                break
        if bbox is None:
            for key in ("dt_poly", "dt_polys", "poly", "polygon", "points", "block_polygon_points", "polygon_points"):
                value = item.get(key)
                if looks_like_poly(value):
                    bbox = poly_to_bbox(value)
                    break

        origin = item.get("type") or item.get("label") or item.get("blockType") or item.get("block_label")
        marker = (text, json.dumps(bbox, ensure_ascii=False) if bbox is not None else None)
        if marker in seen:
            continue
        seen.add(marker)
        candidates.append({"text": text, "bbox": bbox, "origin": origin})
    return candidates


def expand_page_units(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    pages: list[dict[str, Any]] = []
    overall_page = 1
    for record_index, record in enumerate(records, start=1):
        result = record.get("result", {})
        layouts = result.get("layoutParsingResults")
        if isinstance(layouts, list) and layouts:
            for layout_index, layout in enumerate(layouts, start=1):
                pages.append(
                    {
                        "overall_page": overall_page,
                        "record_index": record_index,
                        "layout_index": layout_index,
                        "payload": layout,
                    }
                )
                overall_page += 1
        else:
            pages.append(
                {
                    "overall_page": overall_page,
                    "record_index": record_index,
                    "layout_index": None,
                    "payload": result,
                }
            )
            overall_page += 1
    return pages


def summarize_page_payload(payload: dict[str, Any], page_index: int, record_index: int, layout_index: int | None) -> None:
    print(f"\n=== PDF Page {page_index} (record {record_index}, layout {layout_index}) ===")
    if isinstance(payload, dict):
        print(f"页面顶层键: {', '.join(payload.keys())}")
        pruned = payload.get("prunedResult") or {}
        parsing_res_list = pruned.get("parsing_res_list") or []
        print(f"parsing_res_list: {len(parsing_res_list)}")

    candidates = collect_text_candidates(payload)
    with_bbox = sum(1 for c in candidates if c["bbox"] is not None)
    print(f"文本候选: {len(candidates)}，其中带 bbox: {with_bbox}")
    for item in candidates[:12]:
        preview = item["text"].replace("\n", " ")
        if len(preview) > 80:
            preview = preview[:77] + "..."
        safe_preview = preview.encode("gbk", errors="replace").decode("gbk", errors="replace")
        print(f"  bbox={item['bbox']}  origin={item['origin']}  text={safe_preview}")


def key_hits(record: dict[str, Any], targets: tuple[str, ...]) -> dict[str, int]:
    hits = {key: 0 for key in targets}
    for item in iter_dicts(record):
        for key in targets:
            if key in item:
                hits[key] += 1
    return hits


def build_summary(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    targets = (
        "ocrResults",
        "dt_polys",
        "dt_poly",
        "bbox",
        "box",
        "rect",
        "polygon",
        "points",
        "markdown",
        "rec_texts",
        "prunedResult",
    )
    summary = []
    for page in expand_page_units(records):
        payload = page["payload"]
        candidates = collect_text_candidates(payload)
        summary.append(
            {
                "page": page["overall_page"],
                "record_index": page["record_index"],
                "layout_index": page["layout_index"],
                "result_keys": list(payload.keys()) if isinstance(payload, dict) else [],
                "key_hits": key_hits(payload, targets),
                "candidate_count": len(candidates),
                "candidate_with_bbox": sum(1 for c in candidates if c["bbox"] is not None),
                "candidate_samples": candidates[:12],
            }
        )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="PaddleOCR-VL-1.6 验证脚本")
    parser.add_argument("--token", default=os.environ.get("PADDLE_TOKEN"), help="Paddle token")
    parser.add_argument("--file", default=None, help="待验证的 PDF/图片路径")
    parser.add_argument("--jsonl", default=None, help="已保存的 JSONL 路径；提供后只做本地解析，不发起 OCR 请求")
    args = parser.parse_args()

    if args.jsonl:
        jsonl_path = choose_latest_jsonl() if args.jsonl == "latest" else Path(args.jsonl)
        if not jsonl_path.exists():
            print(f"JSONL 不存在: {jsonl_path}")
            return 1
        print(f"本地解析 JSONL: {jsonl_path}")
        records = load_jsonl_file(jsonl_path)
        stem = jsonl_path.stem
    else:
        if not args.token:
            print("缺少 token，请用 --token 或 PADDLE_TOKEN 提供。")
            return 1

        file_path = Path(args.file) if args.file else choose_default_file()
        if not file_path.exists():
            print(f"文件不存在: {file_path}")
            return 1

        stem = f"ocr_vl_{file_path.stem}"
        print(f"模型: {MODEL}")
        print(f"文件: {file_path}")
        print("提交任务...")
        job_id = submit_job(args.token, file_path)
        print(f"job_id: {job_id}")
        payload = poll_job(args.token, job_id)

        meta_path = OUT_DIR / f"{stem}_job.json"
        save_sample_json(payload, meta_path)

        jsonl_url = payload["resultUrl"]["jsonUrl"]
        records = fetch_jsonl(jsonl_url, stem)

    page_units = expand_page_units(records)
    print(f"JSONL 记录数: {len(records)}")
    print(f"展开后的 PDF 页数: {len(page_units)}")
    if records and not args.jsonl:
        save_sample_json(records[0], OUT_DIR / f"{stem}_page1.json")
    summary = build_summary(records)
    save_sample_json(summary, OUT_DIR / f"{stem}_summary.json")
    for page in page_units:
        summarize_page_payload(page["payload"], page["overall_page"], page["record_index"], page["layout_index"])

    print("\n结论提示:")
    print("1. 如果 layoutParsingResults 为主且 bbox 稀缺，VL 更适合版面/Markdown，不一定适合点读。")
    print("2. 如果 ocrResults 或候选里稳定带 bbox，则可以继续评估是否替代 PP-OCRv6。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
