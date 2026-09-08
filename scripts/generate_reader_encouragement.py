"""Generate the reader's fixed encouragement clips with one VoxCPM voice.

Run with the readalong Conda environment.  A single designed anchor is created
once, then every shipped prompt uses the same Hi-Fi clone reference.  This is
intentional: independent voice-design requests can drift in timbre.
"""

from __future__ import annotations

from pathlib import Path

from app.models.audio import VoiceConfig, VoiceMode
from app.pipeline.definitions import CancellationToken
from app.providers.tts.voxcpm import VoxCpmTtsProvider


ROOT = Path(__file__).parents[1]
OUTPUT = ROOT / "reader_app" / "assets" / "audio" / "encouragement"
ANCHOR = OUTPUT / ".reader-encouragement-anchor.wav"

# Keep the role, age impression, speaking pace and language exactly identical
# for all star bands.  The text that follows the description is the only
# intended difference between clips.
VOICE_DESCRIPTION = (
    "A warm, lively young female Mandarin Chinese children's reading guide, "
    "bright natural smile, clear gentle pronunciation, playful but never "
    "exaggerated, patient encouraging pace"
)
ANCHOR_TEXT = (
    "你好，小朋友，我是你的阅读伙伴。我们一起听故事，认识新单词，"
    "也可以慢慢地再读一次。准备好了吗？让我们开心地开始吧！"
)
CLIPS = {
    "keep_trying.wav": "再试一次吧！",
    "good_job.wav": "真不错，继续哦！",
    "great_job.wav": "太棒啦！",
}


def _trim_silence(path: Path, head_keep_s: float = 0.08, tail_keep_s: float = 0.1) -> None:
    """Remove long lead-in/out pauses VoxCPM sometimes leaves in a clip."""
    import contextlib
    import struct
    import wave

    with contextlib.closing(wave.open(str(path))) as reader:
        params = reader.getparams()
        samples = struct.unpack(
            f"<{params.nframes}h", reader.readframes(params.nframes)
        )
    window = params.framerate // 50  # 20 ms
    rms = [
        (sum(x * x for x in samples[i : i + window]) / window) ** 0.5
        for i in range(0, len(samples) - window, window)
    ]
    if not rms:
        return
    threshold = max(rms) * 0.02
    first = next(i for i, value in enumerate(rms) if value > threshold)
    last = len(rms) - 1 - next(
        i for i, value in enumerate(reversed(rms)) if value > threshold
    )
    head = max(0, first * window - int(head_keep_s * params.framerate))
    tail = min(
        len(samples), (last + 1) * window + int(tail_keep_s * params.framerate)
    )
    trimmed = samples[head:tail]
    with contextlib.closing(wave.open(str(path), "wb")) as writer:
        writer.setparams(params)
        writer.writeframes(struct.pack(f"<{len(trimmed)}h", *trimmed))


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    provider = VoxCpmTtsProvider()
    cancellation = CancellationToken()
    try:
        provider.synthesize(
            ANCHOR_TEXT,
            VoiceConfig(mode=VoiceMode.DESIGN, description=VOICE_DESCRIPTION),
            ANCHOR,
            cancellation,
        )
        clone = VoiceConfig(
            mode=VoiceMode.CLONE,
            reference_wav_path=str(ANCHOR),
            reference_text=ANCHOR_TEXT,
        )
        for filename, text in CLIPS.items():
            print(f"Generating {filename}…", flush=True)
            target = OUTPUT / filename
            provider.synthesize(text, clone, target, cancellation)
            _trim_silence(target)
    finally:
        ANCHOR.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
