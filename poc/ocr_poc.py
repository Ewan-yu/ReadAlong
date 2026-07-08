# -*- coding: utf-8 -*-
"""
ReadAlong — OCR 排雷（PP-OCRv6，AI Studio）
===========================================
验证扫描绘本的"文本 + 坐标(dt_polys)"对应情况（点读关键：点A不能播B）。
PDF 自动转图片（pymupdf），逐页调 PP-OCRv6，提取 dt_polys 行坐标。
⚠️ 验证脚本，非正式代码。token 从环境变量读，不入库。

环境变量：PADDLE_TOKEN
准备：绘本 PDF/图片放到 poc/TestSource/
运行：PADDLE_TOKEN=... python poc/ocr_poc.py
"""
import os
import sys
import json
import time
import requests
from pathlib import Path

OUT = Path(__file__).parent / "out"
OUT.mkdir(exist_ok=True)
SRC_DIR = Path(__file__).parent / "TestSource"

JOB_URL = "https://paddleocr.aistudio-app.com/api/v2/ocr/jobs"
MODEL = "PP-OCRv6"
RETRY_STATUS_CODES = {401, 429, 500, 502, 503, 504}
MIN_SUBMIT_INTERVAL_SECONDS = 0.6
_last_submit_at = 0.0


def pdf_to_images(pdf_path, max_pages=3, dpi=200):
    import fitz  # pymupdf
    doc = fitz.open(str(pdf_path))
    paths = []
    for i in range(min(max_pages, len(doc))):
        pm = doc[i].get_pixmap(dpi=dpi)
        p = OUT / f"page_{i + 1}.png"
        pm.save(str(p))
        paths.append(p)
    doc.close()
    return paths


def request_with_retry(method, url, max_attempts=5, base_delay=2.0, **kwargs):
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


def throttle_submit():
    global _last_submit_at
    elapsed = time.time() - _last_submit_at
    if elapsed < MIN_SUBMIT_INTERVAL_SECONDS:
        time.sleep(MIN_SUBMIT_INTERVAL_SECONDS - elapsed)
    _last_submit_at = time.time()


def submit(token, img_path):
    h = {"Authorization": f"bearer {token}"}
    opt = {"useDocOrientationClassify": False, "useDocUnwarping": False, "useTextlineOrientation": False}
    data = {"model": MODEL, "optionalPayload": json.dumps(opt)}
    throttle_submit()
    with open(img_path, "rb") as f:
        r = request_with_retry("post", JOB_URL, headers=h, data=data, files={"file": f}, timeout=180)
    if r.status_code != 200:
        raise RuntimeError(f"提交失败 {r.status_code}: {r.text[:300]}")
    return r.json()["data"]["jobId"]


def poll(token, job_id, max_wait=180):
    h = {"Authorization": f"bearer {token}"}
    for _ in range(max_wait // 5):
        d = request_with_retry("get", f"{JOB_URL}/{job_id}", headers=h, timeout=30).json()["data"]
        st = d.get("state")
        if st == "done":
            return d["resultUrl"]["jsonUrl"]
        if st == "failed":
            raise RuntimeError(f"任务失败: {d.get('errorMsg')}")
        time.sleep(5)
    raise RuntimeError("轮询超时")


def parse(jsonl_url):
    jl = request_with_retry("get", jsonl_url, timeout=60).text
    first = json.loads(jl.strip().split("\n")[0])
    pr = first["result"]["ocrResults"][0]["prunedResult"]
    return pr.get("rec_texts", []), pr.get("dt_polys", []), jl


def poly_to_bbox(poly):
    """4点多边形 → [x, y, w, h]"""
    if len(poly) < 4:
        return None
    xs = [p[0] for p in poly]
    ys = [p[1] for p in poly]
    return [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]


def main():
    token = os.environ.get("PADDLE_TOKEN")
    if not token:
        print("❌ 请设置 PADDLE_TOKEN"); return
    srcs = sorted(SRC_DIR.glob("*.pdf")) + sorted(SRC_DIR.glob("*.png")) + sorted(SRC_DIR.glob("*.jpg"))
    if not srcs:
        print(f"❌ {SRC_DIR} 无 PDF/图片"); return
    src = srcs[0]
    print(f"OCR: {src.name} ({src.stat().st_size/1024/1024:.1f} MB)")

    # 准备图片
    if src.suffix.lower() == ".pdf":
        print("PDF 转图片（前 3 页，dpi=200）...")
        try:
            import fitz
        except ImportError:
            print("❌ 需 pymupdf: pip install pymupdf"); return
        imgs = pdf_to_images(src, max_pages=3)
    else:
        imgs = [src]

    all_items = []
    for img in imgs:
        print(f"\n--- {img.name} ---")
        print("提交 PP-OCRv6 ...")
        job_id = submit(token, img)
        print(f"jobId: {job_id}，轮询 ...")
        jsonl_url = poll(token, job_id)
        texts, polys, jl = parse(jsonl_url)
        (OUT / f"ocr_{img.stem}.jsonl").write_text(jl, encoding="utf-8")
        print(f"识别 {len(texts)} 行（坐标 {len(polys)}），前 10 行（bbox + 文字）:")
        for i in range(min(10, len(texts))):
            bbox = poly_to_bbox(polys[i]) if i < len(polys) else None
            print(f"  {bbox}  {texts[i][:45]}")
            all_items.append({"page": img.name, "text": texts[i], "bbox": bbox})

    print(f"\n{'=' * 50}\n【结论】")
    print(f"  共 {len(all_items)} 行文字 + bbox 坐标")
    print(f"  原始 JSONL: {OUT}/ocr_*.jsonl")
    print("  → 人工核对：bbox [x,y,w,h] 和文字位置是否对应（点读关键）")
    print("  → 这是绘本点读的 OCR 数据来源，对应清晰即可用")


if __name__ == "__main__":
    main()
