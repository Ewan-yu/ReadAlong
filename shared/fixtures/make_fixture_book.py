# -*- coding: utf-8 -*-
"""M1.1 — 夹具资源包生成器。

产出一本合法的迷你 .readalongbook（2 页 4 句，程序化生成图片与音频），
以及 4 种坏包变体，供 reader_app 的 BookPackValidator 单测使用：

  fixture_book.readalongbook           合法包
  bad_missing_file.readalongbook       缺 align/alignment.db
  bad_bbox.readalongbook               句子 bbox 越界（x+w>1）
  bad_empty_text.readalongbook         句子 text 为空
  bad_path_escape.readalongbook        zip 内含 ../ 路径逃逸条目

用法（无 GPU 依赖，任意 Python>=3.10 + pillow）：
    python shared/fixtures/make_fixture_book.py [输出目录]
默认输出到 shared/fixtures/out/。
"""
from __future__ import annotations

import io
import json
import math
import sqlite3
import struct
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_SQL = REPO_ROOT / "shared" / "schema" / "alignment.sql"

BOOK_ID = "fixture-book-0001"
TITLE = "Fixture Book"
SCHEMA_VERSION = 1

# 2 页，每页 2 句。bbox 为归一化坐标。
PAGES = [
    {"page_no": 1, "sentences": [
        {"id": "s0001", "seq": 1, "text": "Big and small.",
         "bbox": {"x": 0.10, "y": 0.10, "w": 0.60, "h": 0.08}},
        {"id": "s0002", "seq": 2, "text": "My car is small.",
         "bbox": {"x": 0.10, "y": 0.30, "w": 0.70, "h": 0.08}},
    ]},
    {"page_no": 2, "sentences": [
        {"id": "s0003", "seq": 3, "text": "My car is big.",
         "bbox": {"x": 0.15, "y": 0.15, "w": 0.65, "h": 0.08}},
        {"id": "s0004", "seq": 4, "text": "Look at the cars!",
         "bbox": {"x": 0.15, "y": 0.40, "w": 0.70, "h": 0.08}},
    ]},
]

PAGE_W, PAGE_H = 800, 1131  # 迷你尺寸即可（校验器不关心绝对分辨率）


def _make_page_images(out: dict[str, bytes]) -> None:
    """程序化画页面：底色 + 句子框位置画矩形和文字，方便真机肉眼核对 bbox。"""
    from PIL import Image, ImageDraw

    for p in PAGES:
        img = Image.new("RGB", (PAGE_W, PAGE_H), "#F7F5F0")
        d = ImageDraw.Draw(img)
        d.text((30, 30), f"{TITLE} - page {p['page_no']}", fill="#2B2B2B")
        for s in p["sentences"]:
            b = s["bbox"]
            x0, y0 = b["x"] * PAGE_W, b["y"] * PAGE_H
            x1, y1 = (b["x"] + b["w"]) * PAGE_W, (b["y"] + b["h"]) * PAGE_H
            d.rectangle([x0, y0, x1, y1], outline="#1D8A7E", width=3)
            d.text((x0 + 8, y0 + 8), s["text"], fill="#2B2B2B")

        buf = io.BytesIO()
        img.save(buf, "WEBP", quality=82)
        out[f"pages/p{p['page_no']:04d}.webp"] = buf.getvalue()

        thumb = img.resize((PAGE_W // 4, PAGE_H // 4))
        buf = io.BytesIO()
        thumb.save(buf, "JPEG", quality=78)
        out[f"thumbnails/p{p['page_no']:04d}.jpg"] = buf.getvalue()


def _make_beep_ogg(duration_s: float = 1.0, freq: float = 440.0) -> bytes:
    """生成一段正弦 beep 并转 ogg。优先 ffmpeg；没有则退化为 wav 字节直接改后缀
    （just_audio 能按内容识别，夹具用途足够）。"""
    import shutil
    import subprocess
    import tempfile

    rate = 16000
    n = int(rate * duration_s)
    pcm = b"".join(
        struct.pack("<h", int(12000 * math.sin(2 * math.pi * freq * i / rate)))
        for i in range(n)
    )
    wav = (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
           + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
           + b"data" + struct.pack("<I", len(pcm)) + pcm)

    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg:
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "in.wav"
            dst = Path(td) / "out.ogg"
            src.write_bytes(wav)
            subprocess.run([ffmpeg, "-y", "-i", str(src), "-c:a", "libopus",
                            "-b:a", "32k", str(dst)], capture_output=True, check=True)
            return dst.read_bytes()
    return wav  # 退化：wav 内容装进 .ogg 名（仅夹具）


def _make_alignment_db(sentences_override: list | None = None) -> bytes:
    """按 shared/schema/alignment.sql 建库并填夹具数据，返回 db 文件字节。"""
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        db_path = Path(td) / "alignment.db"
        conn = sqlite3.connect(db_path)
        conn.executescript(SCHEMA_SQL.read_text(encoding="utf-8"))
        now = datetime.now(timezone.utc).isoformat()
        conn.execute("INSERT INTO book VALUES (?,?,?,?,?)",
                     (BOOK_ID, TITLE, "en", SCHEMA_VERSION, now))
        for p in PAGES:
            conn.execute(
                "INSERT INTO page (book_id,page_no,image_path,thumbnail_path,"
                "width_px,height_px,source_pdf_page,source_region) VALUES (?,?,?,?,?,?,?,?)",
                (BOOK_ID, p["page_no"], f"pages/p{p['page_no']:04d}.webp",
                 f"thumbnails/p{p['page_no']:04d}.jpg", PAGE_W, PAGE_H,
                 p["page_no"], "full"))

        all_sentences = sentences_override
        if all_sentences is None:
            all_sentences = [
                (s["id"], BOOK_ID, p["page_no"], s["seq"], s["text"],
                 json.dumps(s["bbox"]), 0, f"tts/{s['id']}.ogg", 0.0, 1.0, "tts")
                for p in PAGES for s in p["sentences"]
            ]
        conn.executemany(
            "INSERT INTO sentence (id,book_id,page_no,seq,text,bbox_json,"
            "shared_bbox,audio_path,t_start,t_end,audio_source) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?)", all_sentences)

        # 词级时间戳：只给 s0001（其余句子验证"无 word_timing 降级整句"路径）
        words = ["Big", "and", "small."]
        step = 1.0 / len(words)
        conn.executemany(
            "INSERT INTO word_timing (id,sentence_id,seq,word,t_start,t_end) "
            "VALUES (?,?,?,?,?,?)",
            [(f"s0001_w{i+1}", "s0001", i + 1, w, i * step, (i + 1) * step)
             for i, w in enumerate(words)])
        conn.commit()
        conn.close()
        return db_path.read_bytes()


def _make_manifest() -> bytes:
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "book_id": BOOK_ID,
        "title": TITLE,
        "language": "en",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "generator": {"name": "make_fixture_book", "version": "0.1.0"},
        "page_count": len(PAGES),
        "page_image": {"format": "webp", "max_long_edge_px": 2000, "quality": 82},
        "thumbnail": {"format": "jpg", "max_long_edge_px": 360, "quality": 78},
        "pages": [
            {"page_no": p["page_no"],
             "image": f"pages/p{p['page_no']:04d}.webp",
             "thumbnail": f"thumbnails/p{p['page_no']:04d}.jpg",
             "width_px": PAGE_W, "height_px": PAGE_H,
             "source_pdf_page": p["page_no"], "source_region": "full"}
            for p in PAGES
        ],
    }
    # 生成前先过一遍自家 schema，防夹具本身漂移
    try:
        import jsonschema
        schema = json.loads((REPO_ROOT / "shared" / "schema" / "manifest.schema.json")
                            .read_text(encoding="utf-8"))
        jsonschema.validate(manifest, schema)
    except ImportError:
        print("  (jsonschema 未安装，跳过 manifest 自校验)")
    return json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")


def _build_entries() -> dict[str, bytes]:
    entries: dict[str, bytes] = {}
    _make_page_images(entries)
    beep = _make_beep_ogg()
    for p in PAGES:
        for s in p["sentences"]:
            entries[f"tts/{s['id']}.ogg"] = beep
    entries["align/alignment.db"] = _make_alignment_db()
    entries["manifest.json"] = _make_manifest()
    return entries


def _write_zip(path: Path, entries: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in entries.items():
            z.writestr(name, data)
    print(f"  ✅ {path.name}  ({path.stat().st_size // 1024} KB, {len(entries)} entries)")


def main() -> None:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "out"
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"输出目录: {out_dir}")

    good = _build_entries()
    _write_zip(out_dir / "fixture_book.readalongbook", good)

    # 坏包1：缺 alignment.db
    bad = dict(good)
    del bad["align/alignment.db"]
    _write_zip(out_dir / "bad_missing_file.readalongbook", bad)

    # 坏包2：bbox 越界（s0001 x+w = 1.2 > 1）
    bad_bbox_sentences = [
        ("s0001", BOOK_ID, 1, 1, "Big and small.",
         json.dumps({"x": 0.6, "y": 0.1, "w": 0.6, "h": 0.08}), 0,
         "tts/s0001.ogg", 0.0, 1.0, "tts"),
    ]
    bad = dict(good)
    bad["align/alignment.db"] = _make_alignment_db(bad_bbox_sentences)
    _write_zip(out_dir / "bad_bbox.readalongbook", bad)

    # 坏包3：句子文本为空
    bad_empty_sentences = [
        ("s0001", BOOK_ID, 1, 1, "",
         json.dumps({"x": 0.1, "y": 0.1, "w": 0.6, "h": 0.08}), 0,
         "tts/s0001.ogg", 0.0, 1.0, "tts"),
    ]
    bad = dict(good)
    bad["align/alignment.db"] = _make_alignment_db(bad_empty_sentences)
    _write_zip(out_dir / "bad_empty_text.readalongbook", bad)

    # 坏包4：zip 路径逃逸（解包时必须拒绝）
    bad = dict(good)
    bad["../evil.txt"] = b"path escape"
    _write_zip(out_dir / "bad_path_escape.readalongbook", bad)

    print("\n完成。合法包可直接导入 reader_app；坏包用于 BookPackValidator 单测。")


if __name__ == "__main__":
    main()
