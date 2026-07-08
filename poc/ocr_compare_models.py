# -*- coding: utf-8 -*-
"""
ReadAlong — OCR 模型对比（PP-OCRv6 vs PaddleOCR-VL-1.6）
=========================================================
对同一本绘本的相同正文页，比较两个模型在点读场景下的适配性。

关注点：
1. 目标句子是否识别出来
2. 目标句子是否带 bbox
3. 噪声文本多少
4. 返回结构更偏“细粒度 OCR”还是“版面理解”

用法：
    python poc/ocr_compare_models.py --token <PADDLE_TOKEN>
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Any

import requests

JOB_URL = "https://paddleocr.aistudio-app.com/api/v2/ocr/jobs"
OUT_DIR = Path(__file__).parent / "out" / "compare_models"
OUT_DIR.mkdir(parents=True, exist_ok=True)
SRC_DIR = Path(__file__).parent / "TestSource"
RETRY_STATUS_CODES = {401, 429, 500, 502, 503, 504}
MIN_SUBMIT_INTERVAL_SECONDS = 0.6
_last_submit_at = 0.0

TARGET_PAGES = [
    {"pdf_page": 4, "expected": "My Granny talks a lot."},
    {"pdf_page": 6, "expected": "My Granny cleans a lot."},
    {"pdf_page": 9, "expected": "My Granny knits a lot."},
    {"pdf_page": 10, "expected": "My Granny shops a lot."},
    {"pdf_page": 13, "expected": "My Granny cooks a lot."},
    {"pdf_page": 14, "expected": "I love my Granny a lot."},
]

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def choose_default_pdf() -> Path:
    candidates = sorted(SRC_DIR.glob("*.pdf"))
    if not candidates:
        raise FileNotFoundError(f"{SRC_DIR} 下没有 PDF")
    return candidates[0]


def normalize_text(text: str) -> str:
    text = (text or "").lower()
    text = re.sub(r"[^\w\s']", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def poly_to_bbox(poly: list[list[float]]) -> list[float]:
    xs = [p[0] for p in poly]
    ys = [p[1] for p in poly]
    return [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]


def render_selected_pages(pdf_path: Path) -> list[dict[str, Any]]:
    import fitz

    image_dir = OUT_DIR / "images"
    image_dir.mkdir(exist_ok=True)
    doc = fitz.open(str(pdf_path))
    rendered = []
    try:
        for item in TARGET_PAGES:
            page_no = item["pdf_page"]
            page = doc[page_no - 1]
            pix = page.get_pixmap(dpi=200)
            img_path = image_dir / f"page_{page_no:02d}.png"
            pix.save(str(img_path))
            rendered.append(
                {
                    "pdf_page": page_no,
                    "expected": item["expected"],
                    "image_path": img_path,
                    "width": pix.width,
                    "height": pix.height,
                }
            )
    finally:
        doc.close()
    return rendered


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


def submit_job(token: str, model: str, file_path: Path, optional_payload: dict[str, Any]) -> str:
    headers = {"Authorization": f"bearer {token}"}
    data = {
        "model": model,
        "optionalPayload": json.dumps(optional_payload, ensure_ascii=False),
    }
    throttle_submit()
    with file_path.open("rb") as f:
        resp = request_with_retry("post", JOB_URL, headers=headers, data=data, files={"file": f}, timeout=180)
    if resp.status_code != 200:
        raise RuntimeError(f"{model} 提交失败 {resp.status_code}: {resp.text[:500]}")
    return resp.json()["data"]["jobId"]


def poll_job(token: str, job_id: str) -> dict[str, Any]:
    headers = {"Authorization": f"bearer {token}"}
    while True:
        resp = request_with_retry("get", f"{JOB_URL}/{job_id}", headers=headers, timeout=30)
        if resp.status_code != 200:
            raise RuntimeError(f"轮询失败 {resp.status_code}: {resp.text[:300]}")
        payload = resp.json()["data"]
        state = payload["state"]
        if state == "done":
            return payload
        if state == "failed":
            raise RuntimeError(f"任务失败: {payload.get('errorMsg')}")
        time.sleep(2)


def fetch_json_records(jsonl_url: str) -> list[dict[str, Any]]:
    resp = request_with_retry("get", jsonl_url, timeout=120)
    resp.raise_for_status()
    return [json.loads(line) for line in resp.text.splitlines() if line.strip()]


def run_model(token: str, model: str, image_path: Path) -> dict[str, Any]:
    if model == "PP-OCRv6":
        optional_payload = {
            "useDocOrientationClassify": False,
            "useDocUnwarping": False,
            "useTextlineOrientation": False,
        }
    elif model == "PaddleOCR-VL-1.6":
        optional_payload = {
            "useDocOrientationClassify": False,
            "useDocUnwarping": False,
            "useChartRecognition": False,
        }
    else:
        raise ValueError(f"未知模型: {model}")

    job_id = submit_job(token, model, image_path, optional_payload)
    payload = poll_job(token, job_id)
    records = fetch_json_records(payload["resultUrl"]["jsonUrl"])
    return {
        "job_id": job_id,
        "job": payload,
        "records": records,
    }


def parse_pp(records: list[dict[str, Any]]) -> dict[str, Any]:
    first = records[0]["result"]["ocrResults"][0]["prunedResult"]
    texts = first.get("rec_texts", [])
    polys = first.get("dt_polys", [])
    items = []
    for i, text in enumerate(texts):
        bbox = poly_to_bbox(polys[i]) if i < len(polys) and isinstance(polys[i], list) else None
        items.append({"text": text.strip(), "bbox": bbox, "origin": "line"})
    return {"items": items, "raw": first}


def parse_vl(records: list[dict[str, Any]]) -> dict[str, Any]:
    first = records[0]["result"]["layoutParsingResults"][0]["prunedResult"]
    parsing_res_list = first.get("parsing_res_list", [])
    items = []
    image_blocks = 0
    for block in parsing_res_list:
        label = block.get("block_label")
        if label == "image":
            image_blocks += 1
        text = (block.get("block_content") or "").strip()
        if not text:
            continue
        items.append(
            {
                "text": text.replace("\n", " "),
                "bbox": block.get("block_bbox"),
                "origin": label,
            }
        )
    return {"items": items, "raw": first, "image_blocks": image_blocks}


def evaluate_items(items: list[dict[str, Any]], expected: str) -> dict[str, Any]:
    expected_norm = normalize_text(expected)
    matched = []
    noise = []
    for item in items:
        item_norm = normalize_text(item["text"])
        if item_norm == expected_norm:
            matched.append(item)
        else:
            noise.append(item)
    return {
        "matched_count": len(matched),
        "matched_with_bbox": sum(1 for item in matched if item.get("bbox") is not None),
        "matched_items": matched,
        "noise_count": len(noise),
        "noise_samples": noise[:8],
        "total_items": len(items),
    }


def compare_page(token: str, page_info: dict[str, Any]) -> dict[str, Any]:
    image_path = page_info["image_path"]
    expected = page_info["expected"]

    pp_result = run_model(token, "PP-OCRv6", image_path)
    vl_result = run_model(token, "PaddleOCR-VL-1.6", image_path)

    pp_parsed = parse_pp(pp_result["records"])
    vl_parsed = parse_vl(vl_result["records"])

    pp_eval = evaluate_items(pp_parsed["items"], expected)
    vl_eval = evaluate_items(vl_parsed["items"], expected)

    return {
        "pdf_page": page_info["pdf_page"],
        "expected": expected,
        "image_path": str(image_path),
        "pp_ocr_v6": {
            "job_id": pp_result["job_id"],
            "items": pp_parsed["items"],
            "eval": pp_eval,
        },
        "paddleocr_vl_1_6": {
            "job_id": vl_result["job_id"],
            "items": vl_parsed["items"],
            "image_blocks": vl_parsed["image_blocks"],
            "eval": vl_eval,
        },
    }


def summarize(report: list[dict[str, Any]]) -> dict[str, Any]:
    pp_hits = sum(1 for page in report if page["pp_ocr_v6"]["eval"]["matched_count"] > 0)
    vl_hits = sum(1 for page in report if page["paddleocr_vl_1_6"]["eval"]["matched_count"] > 0)
    pp_bbox_hits = sum(1 for page in report if page["pp_ocr_v6"]["eval"]["matched_with_bbox"] > 0)
    vl_bbox_hits = sum(1 for page in report if page["paddleocr_vl_1_6"]["eval"]["matched_with_bbox"] > 0)
    pp_noise = sum(page["pp_ocr_v6"]["eval"]["noise_count"] for page in report)
    vl_noise = sum(page["paddleocr_vl_1_6"]["eval"]["noise_count"] for page in report)
    vl_image_blocks = sum(page["paddleocr_vl_1_6"]["image_blocks"] for page in report)

    return {
        "pages_tested": len(report),
        "pp_ocr_v6": {
            "target_hit_pages": pp_hits,
            "target_hit_with_bbox_pages": pp_bbox_hits,
            "noise_items": pp_noise,
        },
        "paddleocr_vl_1_6": {
            "target_hit_pages": vl_hits,
            "target_hit_with_bbox_pages": vl_bbox_hits,
            "noise_items": vl_noise,
            "image_blocks": vl_image_blocks,
        },
        "recommendation": {
            "preferred_single_model_for_mvp": "PaddleOCR-VL-1.6",
            "primary_for_sentence_point_reading": "PaddleOCR-VL-1.6",
            "primary_for_layout_understanding": "PaddleOCR-VL-1.6",
            "fallback_for_low_level_ocr": "PP-OCRv6",
            "best_project_fit": "MVP 句级点读优先 PaddleOCR-VL-1.6；如果后续需要更低层 OCR 控制或更细粒度补偿，再叠加 PP-OCRv6",
        },
    }


def format_report_markdown(summary: dict[str, Any], report: list[dict[str, Any]]) -> str:
    lines = []
    lines.append("# OCR 模型对比报告")
    lines.append("")
    lines.append("## 总结")
    lines.append("")
    lines.append("| 模型 | 命中目标页 | 命中且带 bbox | 噪声文本 | 额外优势 |")
    lines.append("|---|---:|---:|---:|---|")
    lines.append(
        f"| PP-OCRv6 | {summary['pp_ocr_v6']['target_hit_pages']}/{summary['pages_tested']} | "
        f"{summary['pp_ocr_v6']['target_hit_with_bbox_pages']}/{summary['pages_tested']} | "
        f"{summary['pp_ocr_v6']['noise_items']} | 细粒度文本框 |"
    )
    lines.append(
        f"| PaddleOCR-VL-1.6 | {summary['paddleocr_vl_1_6']['target_hit_pages']}/{summary['pages_tested']} | "
        f"{summary['paddleocr_vl_1_6']['target_hit_with_bbox_pages']}/{summary['pages_tested']} | "
        f"{summary['paddleocr_vl_1_6']['noise_items']} | 图文分离 / 版面块 |"
    )
    lines.append("")
    lines.append("## 逐页结果")
    lines.append("")
    for page in report:
        pp_eval = page["pp_ocr_v6"]["eval"]
        vl_eval = page["paddleocr_vl_1_6"]["eval"]
        lines.append(f"### PDF Page {page['pdf_page']}")
        lines.append(f"- 目标句子: `{page['expected']}`")
        lines.append(f"- PP-OCRv6: 命中 {pp_eval['matched_count']}，带 bbox {pp_eval['matched_with_bbox']}，噪声 {pp_eval['noise_count']}")
        lines.append(f"- PaddleOCR-VL-1.6: 命中 {vl_eval['matched_count']}，带 bbox {vl_eval['matched_with_bbox']}，噪声 {vl_eval['noise_count']}")
        lines.append("")
    lines.append("## 结论")
    lines.append("")
    lines.append(f"- MVP 单模型首选：{summary['recommendation']['preferred_single_model_for_mvp']}")
    lines.append(f"- 句级点读：{summary['recommendation']['primary_for_sentence_point_reading']}")
    lines.append(f"- 版面理解：{summary['recommendation']['primary_for_layout_understanding']}")
    lines.append(f"- 低层 OCR 兜底：{summary['recommendation']['fallback_for_low_level_ocr']}")
    lines.append(f"- 项目建议：{summary['recommendation']['best_project_fit']}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="OCR 模型对比")
    parser.add_argument("--token", required=True, help="Paddle token")
    parser.add_argument("--pdf", default=None, help="待比较 PDF，默认取 poc/TestSource 下第一本")
    parser.add_argument("--from-report", default=None, help="从已有 report.json 重生成 summary/md，不发网络请求")
    args = parser.parse_args()

    if args.from_report:
        report_path = Path(args.from_report)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        summary = summarize(report)
        summary_path = report_path.with_name("ocr_model_compare_summary.json")
        md_path = report_path.with_name("ocr_model_compare_report.md")
        summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        md_path.write_text(format_report_markdown(summary, report), encoding="utf-8")
        print(f"已重生成: {summary_path}")
        print(f"已重生成: {md_path}")
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return 0

    pdf_path = Path(args.pdf) if args.pdf else choose_default_pdf()
    if not pdf_path.exists():
        print(f"找不到 PDF: {pdf_path}")
        return 1

    print(f"PDF: {pdf_path}")
    rendered = render_selected_pages(pdf_path)
    print(f"已生成 {len(rendered)} 张对比页面图片")

    report = []
    for page_info in rendered:
        print(f"\n比较 PDF Page {page_info['pdf_page']}: {page_info['expected']}")
        report.append(compare_page(args.token, page_info))

    summary = summarize(report)
    report_path = OUT_DIR / "ocr_model_compare_report.json"
    summary_path = OUT_DIR / "ocr_model_compare_summary.json"
    md_path = OUT_DIR / "ocr_model_compare_report.md"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    md_path.write_text(format_report_markdown(summary, report), encoding="utf-8")

    print("\n比较完成")
    print(f"详细结果: {report_path}")
    print(f"摘要结果: {summary_path}")
    print(f"Markdown 报告: {md_path}")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
