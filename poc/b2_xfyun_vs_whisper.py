# -*- coding: utf-8 -*-
"""
ReadAlong — B2 真实验证：Whisper 间接评分 vs 讯飞 ISE
=====================================================
用真实录音，对比"Whisper 间接评分"和"讯飞 ISE 官方评分"的方向一致性。
⚠️ 验证脚本，非正式代码。讯飞 key 从环境变量读，不入库。

环境变量：
  XF_APPID, XF_APIKEY, XF_APISECRET
运行：
  XF_APPID=... XF_APIKEY=... XF_APISECRET=... python poc/b2_xfyun_vs_whisper.py
"""
import os
import sys
import re
import json
import base64
import hashlib
import hmac
import time
import subprocess
import difflib
import threading
from datetime import datetime
from urllib.parse import urlencode, urlparse
from pathlib import Path

_conda_bin = Path(sys.executable).parent / "Library" / "bin"
if _conda_bin.exists():
    os.environ["PATH"] = str(_conda_bin) + os.pathsep + os.environ.get("PATH", "")
FFMPEG = str(_conda_bin / "ffmpeg.exe") if (_conda_bin / "ffmpeg.exe").exists() else "ffmpeg"

OUT = Path(__file__).parent / "out"
OUT.mkdir(exist_ok=True)

SRC = Path(__file__).parent / "TestSource" / "big and small.m4a"
REF_TEXT = "big and small. my car is small. my car is big."


# ============ Whisper 间接评分（复用 B1）============
def _norm(t):
    return re.sub(r"[^\w\s']", " ", (t or "").lower()).split()

def _wer(ref, hyp):
    sm = difflib.SequenceMatcher(None, ref, hyp, autojunk=False)
    s = d = i = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "replace": s += max(i2 - i1, j2 - j1)
        elif tag == "delete": d += i2 - i1
        elif tag == "insert": i += j2 - j1
    return (s + d + i) / len(ref) if ref else 1.0

def _cer(ref, hyp):
    sm = difflib.SequenceMatcher(None, "".join(ref), "".join(hyp), autojunk=False)
    return 1.0 - sm.ratio()

def whisper_score(wav_path, ref_text):
    import stable_whisper
    m = stable_whisper.load_model("base")  # 真实录音用 base 更准
    r = m.transcribe(str(wav_path), language="en")
    ref, hyp = _norm(ref_text), _norm(r.text)
    w, c = _wer(ref, hyp), _cer(ref, hyp)
    sc = round(max(0, 100 * (1 - min(w, c))), 1)
    return {"text": r.text, "wer": round(w, 3), "cer": round(c, 3), "score": sc}


# ============ 讯飞 ISE WebSocket ============
ISE_URL = "wss://ise-api.xfyun.cn/v2/open-ise"

def _auth_url(api_key, api_secret):
    p = urlparse(ISE_URL)
    date = datetime.utcnow().strftime('%a, %d %b %Y %H:%M:%S GMT')
    sig_origin = f"host: {p.netloc}\ndate: {date}\nGET {p.path} HTTP/1.1"
    sig = base64.b64encode(hmac.new(api_secret.encode(), sig_origin.encode(), hashlib.sha256).digest()).decode()
    auth_origin = f'api_key="{api_key}", algorithm="hmac-sha256", headers="host date request-line", signature="{sig}"'
    authorization = base64.b64encode(auth_origin.encode()).decode()
    return ISE_URL + "?" + urlencode({"authorization": authorization, "date": date, "host": p.netloc})

def ise_score(appid, api_key, api_secret, pcm_path, ref_text, category="read_sentence"):
    import websocket
    audio = Path(pcm_path).read_bytes()
    CHUNK = 1280
    text = chr(0xFEFF) + "[content]\n" + ref_text  # BOM 头 + 英文 read_sentence 必须含 [content] 节点
    result = {"xml": None, "err": None}

    def on_open(ws):
        def run():
            # 帧1: ssb 参数上传（不带音频）
            ssb = {
                "common": {"app_id": appid},
                "business": {"sub": "ise", "ent": "en_vip", "category": category,
                             "cmd": "ssb", "aue": "raw", "auf": "audio/L16;rate=16000",
                             "text": text, "tte": "utf-8", "ttp_skip": True,
                             "rst": "entirety", "ise_unite": "1",
                             "extra_ability": "multi_dimension"},
                "data": {"status": 0, "data": ""},
            }
            ws.send(json.dumps(ssb))
            time.sleep(0.04)
            # 帧2..: auw 音频上传（aus=1 首帧 / 2 中间 / 4 末帧）
            n = len(audio)
            for i in range(0, n, CHUNK):
                is_last = (i + CHUNK) >= n
                aus = 1 if i == 0 else (4 if is_last else 2)
                frame = {
                    "business": {"cmd": "auw", "aus": aus},
                    "data": {"status": 2 if is_last else 1,
                             "data": base64.b64encode(audio[i:i + CHUNK]).decode()},
                }
                ws.send(json.dumps(frame))
                time.sleep(0.04)
        threading.Thread(target=run, daemon=True).start()

    def on_message(ws, msg):
        d = json.loads(msg)
        if d.get("code") != 0:
            result["err"] = f'code={d.get("code")} msg={d.get("message")}'
            ws.close(); return
        data = d.get("data", {}) or {}
        if data.get("status") == 2:
            result["xml"] = base64.b64decode(data.get("data", "")).decode("utf-8", errors="replace")
            ws.close()

    def on_error(ws, e): result["err"] = str(e)

    ws = websocket.WebSocketApp(_auth_url(api_key, api_secret),
                                on_open=on_open, on_message=on_message, on_error=on_error)
    ws.run_forever()
    if result["err"]:
        return {"error": result["err"]}
    return _parse_ise_xml(result["xml"])

def _parse_ise_xml(xml):
    def find(attr):
        m = re.search(r'%s="([\d.]+)"' % re.escape(attr), xml or "")
        return float(m.group(1)) if m else None
    return {"total": find("total_score"), "accuracy": find("accuracy_score"),
            "fluency": find("fluency_score"), "standard": find("standard_score"),
            "integrity": find("integrity_score")}


def _to_pcm(src, dst_pcm, dst_wav):
    subprocess.run([FFMPEG, "-y", "-i", str(src), "-f", "s16le", "-acodec", "pcm_s16le",
                    "-ar", "16000", "-ac", "1", str(dst_pcm)], capture_output=True)
    subprocess.run([FFMPEG, "-y", "-i", str(src), "-ar", "16000", "-ac", "1", str(dst_wav)],
                   capture_output=True)
    return dst_pcm.exists() and dst_wav.exists()


def main():
    appid = os.environ.get("XF_APPID"); api_key = os.environ.get("XF_APIKEY")
    api_secret = os.environ.get("XF_APISECRET")
    if not all([appid, api_key, api_secret]):
        print("❌ 请设置 XF_APPID / XF_APIKEY / XF_APISECRET"); return
    if not SRC.exists():
        print(f"❌ 找不到录音: {SRC}"); return

    pcm = OUT / "b2.pcm"; wav = OUT / "b2.wav"
    print("转码音频到 16kHz 单声道...")
    _to_pcm(SRC, pcm, wav)
    print(f"参考文本: {REF_TEXT}\n")

    print("=" * 50, "\n【Whisper 间接评分】")
    ws_r = whisper_score(wav, REF_TEXT)
    print(f"  转写: {ws_r['text']}")
    print(f"  WER={ws_r['wer']}  CER={ws_r['cer']}  → 分数 {ws_r['score']}")

    print("\n", "=" * 50, "\n【讯飞 ISE 评分】")
    ise = ise_score(appid, api_key, api_secret, pcm, REF_TEXT, category="read_sentence")
    if "error" in ise:
        print("  ❌", ise["error"])
        ise_total = None
    else:
        ise_total = ise["total"]
        print(f"  total_score    : {ise['total']}")
        print(f"  accuracy_score : {ise['accuracy']}")
        print(f"  fluency_score  : {ise['fluency']}")
        print(f"  standard_score : {ise['standard']}")
        print(f"  integrity_score: {ise['integrity']}")

    print("\n", "=" * 50, "\n【对比结论】")
    print(f"  Whisper 间接分: {ws_r['score']}")
    print(f"  讯飞 ISE 总分 : {ise_total}")
    if ise_total is not None:
        both_high = ws_r["score"] >= 60 and ise_total >= 60
        both_low = ws_r["score"] < 60 and ise_total < 60
        print(f"  方向一致性: {'✅ 一致（都' + ('高' if both_high else '低') + '）' if (both_high or both_low) else '⚠️ 不一致，需分析'}")
    print("\n注：单样本只能看方向，多样本才能算相关性。")


if __name__ == "__main__":
    main()
