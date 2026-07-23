"""No-model tests for the M5.4 audio mixing PoC."""

from pathlib import Path
import threading

import pytest

from audio_mix_poc import (
    MixInputError,
    MixCancelled,
    MixProcessError,
    _run_cancellable,
    build_mix_plan,
    measurement_command,
    parse_loudnorm_stats,
    render_command,
)


def test_with_background_never_mentions_original_source() -> None:
    plan = build_mix_plan(
        child_wav=Path("takes/child.wav"),
        background_ogg=Path("original/background.ogg"),
        original_source=Path("original/source.mp3"),
        output=Path("out/master.m4a"),
    )

    command = " ".join(measurement_command("ffmpeg", plan))
    assert plan.mode == "with_background"
    assert str(Path("original/background.ogg")) in command
    assert str(Path("original/source.mp3")) not in command
    assert "TP=-1.0" in command
    assert "I=-16.0" in command


def test_source_cannot_be_used_as_background(tmp_path: Path) -> None:
    source = tmp_path / "source.mp3"
    source.write_bytes(b"same bytes")
    disguised_background = tmp_path / "background.ogg"
    disguised_background.write_bytes(b"same bytes")

    with pytest.raises(MixInputError, match="source.mp3"):
        build_mix_plan(
            child_wav=tmp_path / "child.wav",
            background_ogg=disguised_background,
            original_source=source,
            output=tmp_path / "master.m4a",
        )


def test_no_background_is_explicit_voice_only_fallback() -> None:
    plan = build_mix_plan(
        child_wav=Path("takes/child.wav"), output=Path("out/master.wav"))

    assert plan.mode == "voice_only"
    assert "amix" not in plan.filter_graph
    assert "-c:a pcm_s16le" in " ".join(render_command(
        "ffmpeg", plan,
        {"input_i": "-21", "input_lra": "3", "input_tp": "-5", "input_thresh": "-31", "target_offset": "0.1"},
    ))


def test_loudnorm_json_is_parsed_and_invalid_measurement_fails() -> None:
    stats = parse_loudnorm_stats('noise\n{\n  "input_i" : "-21.2"\n}\n')
    assert stats["input_i"] == "-21.2"
    with pytest.raises(MixProcessError):
        parse_loudnorm_stats("no json")


def test_running_ffmpeg_can_be_cancelled_without_a_partial_output() -> None:
    class FakeProcess:
        returncode: int | None = None
        terminated = False

        def poll(self) -> None:
            return None

        def terminate(self) -> None:
            self.terminated = True
            self.returncode = 143

        def wait(self, timeout: float) -> int:
            return 143

        def kill(self) -> None:
            self.returncode = 137

    process = FakeProcess()
    cancel = threading.Event()
    cancel.set()

    with pytest.raises(MixCancelled):
        _run_cancellable(["ffmpeg", "-version"], cancel_event=cancel,
                         popen=lambda *_args, **_kwargs: process)  # type: ignore[arg-type]
    assert process.terminated
