# -*- coding: utf-8 -*-
"""
ReadAlong — VoxCPM 排雷验证脚本（PoC）
======================================
目的：在正式开发前，验证 VoxCPM2 能否作为本项目 TTS 主力方案
验证项：环境 / 基础TTS / 速度(RTF) / 显存 / 声音克隆 / 词级时间戳

⚠️ 这只是验证脚本，不是正式项目代码。

用法：
    python poc/voxcpm_poc.py
    python poc/voxcpm_poc.py --model-path ./pretrained_models/VoxCPM2
    python poc/voxcpm_poc.py --ref-wav path/to/voice.wav
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# 把 conda 环境的 Library/bin 加入 PATH（stable-ts 等依赖 ffmpeg 解码音频）
_conda_bin = Path(sys.executable).parent / "Library" / "bin"
if _conda_bin.exists():
    os.environ["PATH"] = str(_conda_bin) + os.pathsep + os.environ.get("PATH", "")

OUT_DIR = Path(__file__).parent / "out"
OUT_DIR.mkdir(exist_ok=True)

RESULTS = []


def sep(title):
    print(f"\n{'=' * 64}\n{title}\n{'=' * 64}")


def record(name, passed, detail=""):
    RESULTS.append((name, passed, detail))
    flag = "✅ 通过" if passed else "❌ 失败"
    print(f"  → {flag}：{detail}")


# ---------- 步骤 1：环境检查 ----------
def step1_env():
    sep("【步骤 1/4】环境检查：PyTorch + CUDA + GPU")
    try:
        import torch
        cuda = torch.cuda.is_available()
        gpu = torch.cuda.get_device_name(0) if cuda else "（无 CUDA）"
        vram = torch.cuda.get_device_properties(0).total_memory / 1024 ** 3 if cuda else 0
        print(f"  PyTorch 版本 : {torch.__version__}")
        print(f"  CUDA 可用    : {cuda}")
        print(f"  GPU          : {gpu}")
        print(f"  显存总量     : {vram:.1f} GB")
        record("环境检查", cuda, f"GPU={gpu}, 显存={vram:.1f}GB")
        return cuda
    except Exception as e:
        record("环境检查", False, f"异常: {e}")
        return False


# ---------- 加载模型 ----------
def load_model(model_path=None):
    sep("加载 VoxCPM2 模型（首次会下载约几 GB，请耐心等待）")
    from voxcpm import VoxCPM
    src = model_path or "openbmb/VoxCPM2"
    print(f"  来源 : {src}")
    t0 = time.time()
    model = VoxCPM.from_pretrained(src, load_denoiser=False)
    print(f"  加载耗时 : {time.time() - t0:.1f}s")
    return model


# ---------- 步骤 2：基础 TTS + 速度 + 显存 ----------
def step2_basic(model):
    sep("【步骤 2/4】基础 TTS：速度(RTF) + 显存占用")
    import torch
    import soundfile as sf
    text = "Hello! Welcome to ReadAlong. Let's read this picture book together."
    try:
        if torch.cuda.is_available():
            torch.cuda.reset_peak_memory_stats()
        t0 = time.time()
        wav = model.generate(text=text, cfg_value=2.0, inference_timesteps=10)
        elapsed = time.time() - t0
        sr = model.tts_model.sample_rate
        duration = len(wav) / sr
        rtf = elapsed / duration if duration > 0 else 99
        peak = torch.cuda.max_memory_allocated() / 1024 ** 3 if torch.cuda.is_available() else 0
        out = OUT_DIR / "01_basic.wav"
        sf.write(out, wav, sr)
        print(f"  生成耗时 : {elapsed:.2f} s")
        print(f"  音频时长 : {duration:.2f} s")
        print(f"  RTF      : {rtf:.3f}  {'（快于实时 ✓）' if rtf < 1 else '（慢于实时 ✗）'}")
        print(f"  峰值显存 : {peak:.2f} GB")
        print(f"  已保存   : {out}")
        print(f"  → 请人工听 01_basic.wav，判断英文音质与自然度")
        record("速度 RTF<1", rtf < 1, f"RTF={rtf:.3f}, 耗时={elapsed:.2f}s")
        record("显存 <10GB", peak < 10, f"峰值={peak:.2f}GB")
        record("音质（人工）", True, "已生成 01_basic.wav，待人工听辨")
        return wav, sr
    except Exception as e:
        record("基础 TTS", False, f"异常: {e}")
        return None, None


# ---------- 步骤 3：声音克隆 ----------
def step3_clone(model, ref_wav=None):
    sep("【步骤 3/4】声音克隆")
    import soundfile as sf
    # 没给参考音就用 Voice Design 生成一段「伪参考」，至少验证克隆 API 通路
    ref = ref_wav
    if not ref or not Path(ref).exists():
        ref = OUT_DIR / "00_ref.wav"
        if not ref.exists():
            try:
                wav = model.generate(
                    text="(A young female kindergarten teacher, warm and gentle)This is the reference voice.",
                    cfg_value=2.0, inference_timesteps=10,
                )
                sf.write(ref, wav, model.tts_model.sample_rate)
                print(f"  未提供参考音，已用 Voice Design 生成伪参考: {ref}")
            except Exception as e:
                record("声音克隆", False, f"生成伪参考失败: {e}")
                return
        else:
            print(f"  复用已有伪参考: {ref}")
    else:
        print(f"  使用用户参考音: {ref}")

    text = "This is a cloned voice reading a brand new sentence."
    try:
        wav = model.generate(text=text, reference_wav_path=str(ref))
        out = OUT_DIR / "02_clone.wav"
        sf.write(out, wav, model.tts_model.sample_rate)
        print(f"  克隆音频已保存: {out}")
        print(f"  → 请人工对比 02_clone.wav 与参考音，判断音色相似度")
        record("声音克隆 API 通路", True, "已生成 02_clone.wav，相似度待人工判断")
    except Exception as e:
        record("声音克隆", False, f"异常: {e}")


# ---------- 步骤 4：词级时间戳（stable-ts 对生成音频做对齐） ----------
def step4_timestamps():
    sep("【步骤 4/4】词级时间戳（用 stable-ts 对 01_basic.wav 做词级对齐）")
    import json
    wav_path = OUT_DIR / "01_basic.wav"
    if not wav_path.exists():
        record("词级时间戳", False, "缺少 01_basic.wav，请先确保步骤 2 成功")
        return
    try:
        import stable_whisper
        print("  加载 stable-ts (whisper-tiny) 模型（首次会从 HF 下载约 39MB）...")
        st_model = stable_whisper.load_model("tiny")
        print("  对生成音频做词级对齐...")
        result = st_model.transcribe(str(wav_path))
        ts = []
        for seg in result.segments:
            for w in (getattr(seg, "words", None) or []):
                ts.append({"word": w.word.strip(),
                           "start": round(float(w.start), 2),
                           "end": round(float(w.end), 2)})
        out_json = OUT_DIR / "04_timestamps.json"
        out_json.write_text(json.dumps(ts, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"  得到 {len(ts)} 个词的时间戳，示例（前 15 个）:")
        for t in ts[:15]:
            print(f"    {t['start']:5.2f} - {t['end']:5.2f}  {t['word']}")
        print(f"  完整结果: {out_json}")
        record("词级时间戳", len(ts) > 0, f"得到 {len(ts)} 个词级时间戳（stable-ts）")
    except Exception as e:
        record("词级时间戳", False, f"异常: {e}")


# ---------- 汇总 ----------
def summary():
    sep("PoC 结果汇总")
    for name, passed, detail in RESULTS:
        flag = "✅" if passed else "❌"
        print(f"  {flag} {name}：{detail}")
    n_ok = sum(1 for _, p, _ in RESULTS if p)
    total = len(RESULTS)
    print(f"\n  自动判定：{n_ok}/{total} 项通过")
    print("  注：标「人工」的项需你听完音频后自己下结论。")


def main():
    ap = argparse.ArgumentParser(description="VoxCPM 排雷验证（PoC）")
    ap.add_argument("--model-path", default=None,
                    help="本地模型路径（未指定则在线加载 openbmb/VoxCPM2）")
    ap.add_argument("--ref-wav", default=None,
                    help="克隆测试参考音频（未指定则自动生成伪参考）")
    args = ap.parse_args()

    print("ReadAlong — VoxCPM 排雷验证（PoC）")
    print("⚠️ 这只是验证脚本，不是正式项目代码。\n")

    if not step1_env():
        summary()
        print("\n环境检查未通过，请先确保 PyTorch + CUDA 可用。")
        sys.exit(1)

    try:
        model = load_model(args.model_path)
    except Exception as e:
        record("模型加载", False, f"异常: {e}")
        summary()
        sys.exit(1)

    step2_basic(model)
    step3_clone(model, args.ref_wav)
    step4_timestamps()
    summary()


if __name__ == "__main__":
    main()
