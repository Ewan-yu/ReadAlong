from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from difflib import SequenceMatcher
from pathlib import Path

import stable_whisper


def _tokens(text: str) -> list[str]:
    return re.findall(r"[a-z]+(?:'[a-z]+)?", text.lower())


def _transcribe(model, path: Path) -> dict[str, object]:
    result = model.transcribe(str(path), language="en", word_timestamps=False)
    segments = list(result.segments)
    text = " ".join(segment.text.strip() for segment in segments).strip()
    return {
        "text": text,
        "tokens": _tokens(text),
        "segment_count": len(segments),
        "average_log_probability": (
            sum(float(segment.avg_logprob) for segment in segments) / len(segments)
            if segments
            else None
        ),
        "average_no_speech_probability": (
            sum(float(segment.no_speech_prob) for segment in segments) / len(segments)
            if segments
            else None
        ),
    }


def _compare(reference: list[str], candidate: list[str]) -> dict[str, float | int]:
    reference_counts = Counter(reference)
    candidate_counts = Counter(candidate)
    overlap = sum((reference_counts & candidate_counts).values())
    return {
        "candidate_token_count": len(candidate),
        "reference_token_recall": overlap / len(reference) if reference else 0.0,
        "sequence_similarity": SequenceMatcher(None, reference, candidate).ratio(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="用本地 Whisper 定量比较 Demucs 人声保留和背景旁白残留。"
    )
    parser.add_argument(
        "report",
        type=Path,
        help="demucs_separation_poc.py 生成的 separation_report.json。",
    )
    parser.add_argument("--model", default="tiny")
    args = parser.parse_args()

    conda_bin = Path(sys.prefix) / "Library" / "bin"
    if (conda_bin / "ffmpeg.exe").is_file():
        os.environ["PATH"] = str(conda_bin) + os.pathsep + os.environ.get("PATH", "")
    report_path = args.report.expanduser().resolve(strict=True)
    report = json.loads(report_path.read_text(encoding="utf-8"))
    source = Path(report["source"]["path"])
    model = stable_whisper.load_model(args.model)

    source_result = _transcribe(model, source)
    reference = source_result.pop("tokens")
    analysis: dict[str, object] = {
        "asr_model": args.model,
        "source": {**source_result, "token_count": len(reference)},
        "models": {},
        "interpretation": (
            "Whisper 对音乐可能产生幻觉；背景 token recall/sequence similarity 仅作为旁白残留筛查，"
            "不能替代开头、中段、结尾人工试听。"
        ),
    }
    for model_name, model_report in report["models"].items():
        if model_report.get("status") != "completed":
            continue
        model_dir = report_path.parent / model_name
        vocals_result = _transcribe(model, model_dir / "vocals.wav")
        background_result = _transcribe(model, model_dir / "no_vocals.wav")
        vocals_tokens = vocals_result.pop("tokens")
        background_tokens = background_result.pop("tokens")
        analysis["models"][model_name] = {  # type: ignore[index]
            "vocals": {
                **vocals_result,
                **_compare(reference, vocals_tokens),
            },
            "background": {
                **background_result,
                **_compare(reference, background_tokens),
            },
        }

    output = report_path.with_name("leakage_analysis.json")
    output.write_text(json.dumps(analysis, ensure_ascii=False, indent=2), encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
