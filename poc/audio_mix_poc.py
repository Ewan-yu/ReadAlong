#!/usr/bin/env python3
"""M5.4 本地混音 PoC：儿童录音 + 已确认背景轨。

This is deliberately a command-line proof of concept.  It does not download
models, mutate a book workspace, or make any reader-app dependency choice.
Only a reviewed ``original/background.ogg`` may be used as the optional music
input.  In particular, ``original/source.mp3`` is never an ffmpeg input: it
contains the narrator and would make a child duet with the original reader.

The rendered master is normalised to -16 LUFS and -1 dBTP.  If no reviewed
background is available, the exact same pipeline renders a clearly-labelled
``voice_only`` master instead of silently using the original source audio.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence


TARGET_I_LUFS = -16.0
TARGET_TRUE_PEAK_DBTP = -1.0
DEFAULT_BACKGROUND_GAIN_DB = -18.0
_LOUDNORM_JSON = re.compile(r"\{\s*\"input_i\".*?\}", re.DOTALL)


class MixInputError(ValueError):
    """An input would violate the product's narrator-safety contract."""


class MixCancelled(RuntimeError):
    """The caller cancelled a running ffmpeg operation."""


class MixProcessError(RuntimeError):
    """ffmpeg did not produce a valid master."""


@dataclass(frozen=True)
class MixPlan:
    """A declarative command plan, kept testable without ffmpeg installed."""

    child_wav: Path
    background_ogg: Path | None
    output: Path
    mode: str
    filter_graph: str


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _same_file(left: Path, right: Path) -> bool:
    """Compare resolved paths first, then contents when both files exist."""

    if left.resolve(strict=False) == right.resolve(strict=False):
        return True
    return left.is_file() and right.is_file() and _sha256(left) == _sha256(right)


def build_mix_plan(
    *,
    child_wav: Path,
    output: Path,
    background_ogg: Path | None = None,
    original_source: Path | None = None,
    background_gain_db: float = DEFAULT_BACKGROUND_GAIN_DB,
) -> MixPlan:
    """Create a safe mix plan without accessing ffmpeg.

    ``original_source`` is accepted only to detect accidental selection.  It is
    never returned as an input and must never appear in generated commands.
    """

    if child_wav.suffix.lower() != ".wav":
        raise MixInputError("儿童录音必须是 WAV，不能把原音当作录音输入。")
    if background_ogg is not None and background_ogg.suffix.lower() != ".ogg":
        raise MixInputError("背景轨只能使用已确认导出的 original/background.ogg。")
    if output.resolve(strict=False) == child_wav.resolve(strict=False):
        raise MixInputError("混音输出不能覆盖儿童原始录音。")
    if not -36.0 <= background_gain_db <= -6.0:
        raise MixInputError("背景音量必须在 -36 dB 到 -6 dB 之间。")
    if original_source is not None:
        if _same_file(child_wav, original_source):
            raise MixInputError("儿童录音不能指向 original/source.mp3。")
        if background_ogg is not None and _same_file(background_ogg, original_source):
            raise MixInputError("禁止把 original/source.mp3 作为背景叠加到儿童录音。")

    # aresample first makes the two-pass loudnorm output deterministic.  The
    # child stays at unity gain; only the reviewed music receives attenuation.
    if background_ogg is None:
        mode = "voice_only"
        filter_graph = "[0:a]aresample=48000,pan=mono|c0=c0[mix]"
    else:
        mode = "with_background"
        filter_graph = (
            "[0:a]aresample=48000,pan=mono|c0=c0[child];"
            f"[1:a]aresample=48000,volume={background_gain_db}dB[background];"
            "[child][background]amix=inputs=2:duration=first:normalize=0,"
            "aresample=48000[mix]"
        )
    return MixPlan(
        child_wav=child_wav,
        background_ogg=background_ogg,
        output=output,
        mode=mode,
        filter_graph=filter_graph,
    )


def _codec_args(output: Path) -> list[str]:
    suffix = output.suffix.lower()
    if suffix == ".wav":
        return ["-c:a", "pcm_s16le"]
    if suffix in {".m4a", ".mp4"}:
        return ["-c:a", "aac", "-b:a", "192k"]
    if suffix == ".ogg":
        return ["-c:a", "libopus", "-b:a", "128k"]
    raise MixInputError("输出仅支持 .wav、.m4a 或 .ogg。")


def _input_args(plan: MixPlan) -> list[str]:
    args = ["-i", str(plan.child_wav)]
    if plan.background_ogg is not None:
        args.extend(["-stream_loop", "-1", "-i", str(plan.background_ogg)])
    return args


def _loudnorm_filter(stats: dict[str, str] | None = None) -> str:
    if stats is None:
        return (
            f"loudnorm=I={TARGET_I_LUFS}:LRA=11:TP={TARGET_TRUE_PEAK_DBTP}:"
            "print_format=json"
        )
    required = ("input_i", "input_lra", "input_tp", "input_thresh", "target_offset")
    try:
        values = {key: float(stats[key]) for key in required}
    except (KeyError, TypeError, ValueError) as error:
        raise MixProcessError("ffmpeg 未返回可用的响度测量结果。") from error
    return (
        f"loudnorm=I={TARGET_I_LUFS}:LRA=11:TP={TARGET_TRUE_PEAK_DBTP}:"
        f"measured_I={values['input_i']}:measured_LRA={values['input_lra']}:"
        f"measured_TP={values['input_tp']}:measured_thresh={values['input_thresh']}:"
        f"offset={values['target_offset']}:linear=true:print_format=summary"
    )


def measurement_command(ffmpeg: str, plan: MixPlan) -> list[str]:
    return [
        ffmpeg, "-hide_banner", "-nostdin", "-y", *_input_args(plan),
        "-filter_complex", f"{plan.filter_graph};[mix]{_loudnorm_filter()}[out]",
        "-map", "[out]", "-f", "null", os.devnull,
    ]


def render_command(ffmpeg: str, plan: MixPlan, stats: dict[str, str]) -> list[str]:
    return [
        ffmpeg, "-hide_banner", "-nostdin", "-y", *_input_args(plan),
        "-filter_complex", f"{plan.filter_graph};[mix]{_loudnorm_filter(stats)}[out]",
        "-map", "[out]", *_codec_args(plan.output), str(plan.output),
    ]


def parse_loudnorm_stats(stderr: str) -> dict[str, str]:
    matches = _LOUDNORM_JSON.findall(stderr)
    if not matches:
        raise MixProcessError("ffmpeg 响度分析失败：未找到 loudnorm JSON。")
    try:
        result = json.loads(matches[-1])
    except json.JSONDecodeError as error:
        raise MixProcessError("ffmpeg 返回了无法解析的 loudnorm JSON。") from error
    if not isinstance(result, dict):
        raise MixProcessError("ffmpeg 返回了非法的 loudnorm 测量结果。")
    return {str(key): str(value) for key, value in result.items()}


def _run_cancellable(
    command: Sequence[str],
    *,
    cancel_event: threading.Event | None,
    popen: Callable[..., subprocess.Popen[str]] = subprocess.Popen,
) -> str:
    """Run ffmpeg and terminate it promptly when a UI cancellation arrives."""

    process = popen(list(command), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    while process.poll() is None:
        if cancel_event is not None and cancel_event.is_set():
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
            raise MixCancelled("混音已取消；没有保存不完整的作品。")
        cancel_event.wait(0.1) if cancel_event is not None else threading.Event().wait(0.1)
    _stdout, stderr = process.communicate()
    if process.returncode:
        raise MixProcessError(f"ffmpeg 退出码 {process.returncode}：{stderr[-800:]}")
    return stderr


def render_mix(
    *,
    ffmpeg: str,
    plan: MixPlan,
    cancel_event: threading.Event | None = None,
) -> dict[str, object]:
    """Measure then render atomically; remove partial output on failure/cancel."""

    for source in (plan.child_wav, plan.background_ogg):
        if source is not None and not source.is_file():
            raise MixInputError(f"找不到输入音频：{source}")
    plan.output.parent.mkdir(parents=True, exist_ok=True)
    # Keep the real container extension last: ffmpeg selects its muxer from it.
    temporary = plan.output.with_name(
        f"{plan.output.stem}.part{plan.output.suffix}")
    render_plan = MixPlan(
        child_wav=plan.child_wav,
        background_ogg=plan.background_ogg,
        output=temporary,
        mode=plan.mode,
        filter_graph=plan.filter_graph,
    )
    try:
        stats = parse_loudnorm_stats(_run_cancellable(
            measurement_command(ffmpeg, plan), cancel_event=cancel_event))
        _run_cancellable(render_command(ffmpeg, render_plan, stats), cancel_event=cancel_event)
        if not temporary.is_file() or temporary.stat().st_size == 0:
            raise MixProcessError("ffmpeg 未写出有效混音文件。")
        temporary.replace(plan.output)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return {
        "mode": plan.mode,
        "output": str(plan.output),
        "target_integrated_lufs": TARGET_I_LUFS,
        "target_true_peak_dbtp": TARGET_TRUE_PEAK_DBTP,
        "background_gain_db": DEFAULT_BACKGROUND_GAIN_DB if plan.background_ogg else None,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="ReadAlong M5.4 离线混音 PoC")
    parser.add_argument("--child-wav", required=True, type=Path, help="儿童录音 WAV")
    parser.add_argument("--background-ogg", type=Path, help="已确认的 original/background.ogg")
    parser.add_argument("--original-source", type=Path, help="仅用于安全校验，绝不会参与混音")
    parser.add_argument("--output", required=True, type=Path, help="输出 .wav/.m4a/.ogg")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--background-gain-db", type=float, default=DEFAULT_BACKGROUND_GAIN_DB)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        plan = build_mix_plan(
            child_wav=args.child_wav,
            background_ogg=args.background_ogg,
            original_source=args.original_source,
            output=args.output,
            background_gain_db=args.background_gain_db,
        )
        result = render_mix(ffmpeg=args.ffmpeg, plan=plan)
    except (MixInputError, MixProcessError, MixCancelled) as error:
        print(f"混音未完成：{error}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
