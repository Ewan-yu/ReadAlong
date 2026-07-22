from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from demucs.apply import apply_model
from demucs.audio import save_audio
from demucs.pretrained import get_model
from demucs.separate import load_track


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _ffprobe(path: Path, ffprobe: Path) -> dict[str, object]:
    completed = subprocess.run(
        [
            str(ffprobe),
            "-v",
            "error",
            "-show_entries",
            "format=duration:stream=sample_rate,channels,codec_name",
            "-of",
            "json",
            str(path),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=True,
    )
    payload = json.loads(completed.stdout)
    stream = next(item for item in payload["streams"] if "sample_rate" in item)
    return {
        "duration_seconds": float(payload["format"]["duration"]),
        "sample_rate": int(stream["sample_rate"]),
        "channels": int(stream["channels"]),
        "codec": stream.get("codec_name"),
    }


def _wav_metrics(path: Path) -> dict[str, object]:
    info = sf.info(path)
    peak = 0.0
    square_sum = 0.0
    sample_count = 0
    with sf.SoundFile(path) as stream:
        for block in stream.blocks(blocksize=65536, dtype="float32", always_2d=True):
            peak = max(peak, float(np.max(np.abs(block))))
            square_sum += float(np.square(block, dtype=np.float64).sum())
            sample_count += block.size
    rms = math.sqrt(square_sum / sample_count) if sample_count else 0.0
    return {
        "duration_seconds": info.duration,
        "sample_rate": info.samplerate,
        "channels": info.channels,
        "frames": info.frames,
        "size_bytes": path.stat().st_size,
        "peak_dbfs": 20 * math.log10(peak) if peak > 0 else None,
        "rms_dbfs": 20 * math.log10(rms) if rms > 0 else None,
    }


def _make_previews(
    *,
    ffmpeg: Path,
    duration: float,
    original: Path,
    vocals: Path,
    background: Path,
    output: Path,
) -> None:
    clip_seconds = min(12.0, duration)
    positions = {
        "start": 0.0,
        "middle": max(0.0, duration / 2 - clip_seconds / 2),
        "end": max(0.0, duration - clip_seconds),
    }
    for position, start in positions.items():
        position_dir = output / position
        position_dir.mkdir(parents=True, exist_ok=True)
        for label, source in (
            ("original", original),
            ("vocals", vocals),
            ("background", background),
        ):
            subprocess.run(
                [
                    str(ffmpeg),
                    "-y",
                    "-ss",
                    f"{start:.3f}",
                    "-i",
                    str(source),
                    "-t",
                    f"{clip_seconds:.3f}",
                    "-c:a",
                    "libopus",
                    "-b:a",
                    "96k",
                    str(position_dir / f"{label}.ogg"),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                check=True,
            )


def _separate(
    *,
    model_name: str,
    source: Path,
    output: Path,
    device: str,
    shifts: int,
    overlap: float,
    segment: float | None,
    ffmpeg: Path,
    input_duration: float,
) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    model_started = time.perf_counter()
    model = get_model(model_name)
    model.cpu().eval()
    model_load_seconds = time.perf_counter() - model_started
    wav = load_track(source, model.audio_channels, model.samplerate)
    reference = wav.mean(0)
    reference_mean = reference.mean()
    reference_std = reference.std()
    if not torch.isfinite(reference_std) or reference_std <= 0:
        raise RuntimeError("source audio has no usable dynamic range")
    wav = (wav - reference_mean) / reference_std

    if device.startswith("cuda"):
        torch.cuda.empty_cache()
        torch.cuda.reset_peak_memory_stats()
    inference_started = time.perf_counter()
    sources = apply_model(
        model,
        wav[None],
        device=device,
        shifts=shifts,
        split=True,
        overlap=overlap,
        progress=True,
        num_workers=0,
        segment=segment,
    )[0]
    if device.startswith("cuda"):
        torch.cuda.synchronize()
    inference_seconds = time.perf_counter() - inference_started
    sources = sources * reference_std + reference_mean

    vocals_index = model.sources.index("vocals")
    vocals = sources[vocals_index]
    background = torch.zeros_like(vocals)
    for index, stem in enumerate(sources):
        if index != vocals_index:
            background += stem

    vocals_path = output / "vocals.wav"
    background_path = output / "no_vocals.wav"
    for audio, path in ((vocals, vocals_path), (background, background_path)):
        save_audio(
            audio,
            str(path),
            samplerate=model.samplerate,
            clip="clamp",
            as_float=True,
        )

    vocals_metrics = _wav_metrics(vocals_path)
    background_metrics = _wav_metrics(background_path)
    _make_previews(
        ffmpeg=ffmpeg,
        duration=input_duration,
        original=source,
        vocals=vocals_path,
        background=background_path,
        output=output / "previews",
    )
    report = {
        "status": "completed",
        "model": model_name,
        "model_sources": list(model.sources),
        "model_load_seconds": model_load_seconds,
        "inference_seconds": inference_seconds,
        "realtime_factor": inference_seconds / input_duration,
        "peak_cuda_allocated_mb": (
            torch.cuda.max_memory_allocated() / 1024 / 1024
            if device.startswith("cuda")
            else None
        ),
        "peak_cuda_reserved_mb": (
            torch.cuda.max_memory_reserved() / 1024 / 1024
            if device.startswith("cuda")
            else None
        ),
        "vocals": vocals_metrics,
        "background": background_metrics,
        "max_duration_drift_ms": max(
            abs(float(vocals_metrics["duration_seconds"]) - input_duration),
            abs(float(background_metrics["duration_seconds"]) - input_duration),
        )
        * 1000,
    }
    del sources, vocals, background, model, wav
    if device.startswith("cuda"):
        torch.cuda.empty_cache()
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="ReadAlong M5 Demucs 双模型分离 PoC。")
    parser.add_argument("source", type=Path)
    parser.add_argument("--out", type=Path, default=Path(__file__).parent / "out" / "demucs")
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--models", nargs="+", default=["htdemucs", "htdemucs_ft"])
    parser.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    parser.add_argument("--shifts", type=int, default=1)
    parser.add_argument("--overlap", type=float, default=0.25)
    parser.add_argument("--segment", type=float)
    args = parser.parse_args()

    source = args.source.expanduser().resolve(strict=True)
    output = args.out.expanduser().resolve()
    cache = args.cache.expanduser().resolve()
    torch.hub.set_dir(str(cache / "hub"))
    ffmpeg_value = shutil.which("ffmpeg")
    ffprobe_value = shutil.which("ffprobe")
    if not ffmpeg_value or not ffprobe_value:
        conda_bin = Path(sys.prefix) / "Library" / "bin"
        ffmpeg_value = ffmpeg_value or str(conda_bin / "ffmpeg.exe")
        ffprobe_value = ffprobe_value or str(conda_bin / "ffprobe.exe")
    ffmpeg, ffprobe = Path(ffmpeg_value), Path(ffprobe_value)
    if not ffmpeg.is_file() or not ffprobe.is_file():
        raise RuntimeError("ffmpeg/ffprobe not found")
    if args.device.startswith("cuda") and not torch.cuda.is_available():
        raise RuntimeError("CUDA requested but unavailable")

    output.mkdir(parents=True, exist_ok=True)
    source_info = _ffprobe(source, ffprobe)
    report: dict[str, object] = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source": {
            "path": str(source),
            "size_bytes": source.stat().st_size,
            "sha256": _sha256(source),
            **source_info,
        },
        "environment": {
            "python": sys.version,
            "torch": torch.__version__,
            "torchaudio": importlib.metadata.version("torchaudio"),
            "demucs": importlib.metadata.version("demucs"),
            "device": args.device,
            "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
            "shifts": args.shifts,
            "overlap": args.overlap,
            "segment": args.segment,
            "model_cache": str(cache),
        },
        "models": {},
    }
    report_path = output / "separation_report.json"
    failures = 0
    for model_name in args.models:
        print(f"\n=== {model_name} ===", flush=True)
        try:
            model_report = _separate(
                model_name=model_name,
                source=source,
                output=output / model_name,
                device=args.device,
                shifts=args.shifts,
                overlap=args.overlap,
                segment=args.segment,
                ffmpeg=ffmpeg,
                input_duration=float(source_info["duration_seconds"]),
            )
            report["models"][model_name] = model_report  # type: ignore[index]
        except Exception as exc:
            failures += 1
            report["models"][model_name] = {  # type: ignore[index]
                "status": "failed",
                "error_type": type(exc).__name__,
                "error": str(exc),
            }
        report_path.write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    print(f"\nReport: {report_path}")
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
