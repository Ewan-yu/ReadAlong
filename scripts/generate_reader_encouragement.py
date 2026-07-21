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
    "keep_trying.wav": "没关系，慢慢来。你已经读得很认真了，再试一次，一定会更棒！",
    "good_job.wav": "读得真不错！你的声音越来越清楚了，继续加油！",
    "great_job.wav": "太棒啦！你读得又清楚又自信，给你一颗闪亮的小星星！",
}


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
            provider.synthesize(text, clone, OUTPUT / filename, cancellation)
    finally:
        ANCHOR.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
