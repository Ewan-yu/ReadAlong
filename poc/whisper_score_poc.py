# -*- coding: utf-8 -*-
"""
ReadAlong — Whisper 间接评分 PoC（B1）
======================================
验证"用 ASR 转写对比参考文本"的免费间接评分法：
  录音 -> Whisper 转写 -> 与参考文本算 WER -> 映射分数 -> 错词定位

验证逻辑链 + 用模拟样本测区分力（标准 vs 加噪声 vs 含糊）。
⚠️ 这是验证脚本，不是正式项目代码。真实发音准确性验证见 B2（需真实录音+讯飞对比）。
"""
import os
import sys
import re
import json
import subprocess
import difflib
from pathlib import Path

# 把 conda 环境的 Library/bin 加入 PATH（whisper 解码音频要用 ffmpeg）
_conda_bin = Path(sys.executable).parent / "Library" / "bin"
if _conda_bin.exists():
    os.environ["PATH"] = str(_conda_bin) + os.pathsep + os.environ.get("PATH", "")

OUT = Path(__file__).parent / "out"
OUT.mkdir(exist_ok=True)

# 参考文本（与 01_basic.wav 内容一致，标点/大小写归一化后用）
REF_TEXT = "Hello! Welcome to ReadAlong. Let's read this picture book together."


def normalize(text):
    """归一化：小写 + 去标点 + 分词"""
    text = re.sub(r"[^\w\s']", " ", (text or "").lower())
    return text.split()


def wer_with_ops(ref_words, hyp_words):
    """词级 WER + 错词定位。返回 (wer, [(op, 应读, 识别为), ...])"""
    sm = difflib.SequenceMatcher(None, ref_words, hyp_words, autojunk=False)
    s = d = ins = 0
    ops = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        ref_seg = ref_words[i1:i2]
        hyp_seg = hyp_words[j1:j2]
        ops.append((tag, ref_seg, hyp_seg))
        if tag == "replace":
            s += max(i2 - i1, j2 - j1)
        elif tag == "delete":
            d += (i2 - i1)
        elif tag == "insert":
            ins += (j2 - j1)
    n = len(ref_words)
    w = (s + d + ins) / n if n else 1.0
    return w, ops


def wer_to_score(w):
    """WER -> 0-100 分（线性：WER 0=100，WER>=1=0）"""
    return round(max(0.0, 100.0 * (1.0 - w)), 1)


def cer(ref_words, hyp_words):
    """字符错误率：去空格后字符级差异，对分词拆分(如 ReadAlong vs Read Along)容错"""
    ref_str = "".join(ref_words)
    hyp_str = "".join(hyp_words)
    sm = difflib.SequenceMatcher(None, ref_str, hyp_str, autojunk=False)
    return 1.0 - sm.ratio()


def combined_score(w, c):
    """综合分数：取 WER 与 CER 中更宽松者，避免分词差异误扣分"""
    err = min(w, c)
    return round(max(0.0, 100.0 * (1.0 - err)), 1)


def make_degraded(src, dst, mode):
    """用 ffmpeg 造'发音差'的模拟样本"""
    if not src.exists():
        return False
    if mode == "muddy":  # 降采样：丢高频，模拟含糊不清
        cmd = ["ffmpeg", "-y", "-i", str(src),
               "-af", "aresample=3500,aresample=24000",
               "-ac", "1", str(dst)]
    elif mode == "noisy":  # 混入强白噪声
        cmd = ["ffmpeg", "-y", "-i", str(src),
               "-f", "lavfi", "-t", "10", "-i",
               "anoisesrc=color=white:amplitude=0.6",
               "-filter_complex", "[0][1]amix=inputs=2:duration=first",
               str(dst)]
    else:
        return False
    r = subprocess.run(cmd, capture_output=True)
    return dst.exists() and dst.stat().st_size > 0


def main():
    import stable_whisper
    print("ReadAlong — Whisper 间接评分 PoC（B1）")
    print("⚠️ 方法验证 + 模拟样本，真实准确性见 B2。\n")

    print("加载 whisper-tiny...")
    model = stable_whisper.load_model("tiny")

    ref = normalize(REF_TEXT)
    print(f"参考文本（{len(ref)} 词）: {REF_TEXT}\n")

    # 准备样本
    samples = []
    base = OUT / "01_basic.wav"
    if base.exists():
        samples.append(("标准清晰", base))
    noisy = OUT / "05_noisy.wav"
    if make_degraded(base, noisy, "noisy"):
        samples.append(("强白噪声", noisy))
    muddy = OUT / "06_muddy.wav"
    if make_degraded(base, muddy, "muddy"):
        samples.append(("降采样含糊", muddy))

    # 转写 + 评分
    print(f"{'样本':<10} {'WER':>6} {'CER':>6} {'分数':>7}   转写结果")
    print("-" * 78)
    rows = []
    for name, path in samples:
        r = model.transcribe(str(path))
        hyp = normalize(r.text)
        w, ops = wer_with_ops(ref, hyp)
        c = cer(ref, hyp)
        sc = combined_score(w, c)
        print(f"{name:<10} {w:>6.2f} {c:>6.2f} {sc:>6.1f}   {r.text}")
        rows.append({"name": name, "wer": w, "cer": c, "score": sc, "text": r.text, "ops": ops})

    # 错词定位示例
    print("\n=== 错词定位示例（取 WER 最高的样本）===")
    worst = max(rows, key=lambda x: x["wer"])
    if worst["ops"]:
        print(f"样本【{worst['name']}】（分数 {worst['score']}）：")
        for tag, ref_seg, hyp_seg in worst["ops"][:8]:
            tag_cn = {"replace": "读错", "delete": "漏读", "insert": "多读"}.get(tag, tag)
            print(f"  [{tag_cn}] 应读 {ref_seg}  ->  识别为 {hyp_seg}")
    else:
        print(f"样本【{worst['name']}】无错词，转写完全正确。")

    # 存结果
    (OUT / "05_score_result.json").write_text(
        json.dumps([{k: v for k, v in row.items() if k != "ops"} |
                    {"ops": [(t, r2, h) for t, r2, h in row["ops"]]} for row in rows],
                   ensure_ascii=False, indent=2), encoding="utf-8")

    # 结论
    print("\n=== 结论 ===")
    std = next((x for x in rows if x["name"] == "标准清晰"), None)
    bad = next((x for x in rows if x["wer"] == max(r["wer"] for r in rows)), None)
    if std and bad:
        if std["score"] > bad["score"]:
            print(f"✅ 有区分力：标准版 {std['score']} 分 vs 最差版 {bad['score']} 分")
            print(f"   间接评分能反映'可懂度'差异。")
        else:
            print(f"⚠️ 区分力弱：标准 {std['score']} 分 vs 最差 {bad['score']} 分")
            print(f"   whisper-tiny 对该破坏鲁棒，需更强破坏或更大模型才见差异。")
    print("\n注：间接评分反映的是'可懂度'（能否被听懂），非精细发音纠正。")
    print("    真实发音准确性需 B2（真实儿童录音 + 讯飞 ISE 对比）验证。")


if __name__ == "__main__":
    main()
