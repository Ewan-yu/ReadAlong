from pathlib import Path

import numpy

from app.models.audio import VoiceConfig, VoiceMode
from app.pipeline.definitions import CancellationToken
from app.providers.tts.voxcpm import VoxCpmTtsProvider


class _FakeModel:
    class tts_model:
        sample_rate = 16000

    def __init__(self) -> None:
        self.options: dict[str, object] | None = None

    def generate(self, **options: object):
        self.options = options
        return numpy.full(1600, 0.1, dtype=numpy.float32)


def test_hifi_clone_passes_the_same_reference_as_prompt_with_its_exact_text(tmp_path: Path) -> None:
    model = _FakeModel()
    provider = VoxCpmTtsProvider(model_path=tmp_path)
    provider._model = model
    reference = tmp_path / "reference.wav"
    reference.write_bytes(b"reference")

    provider.synthesize(
        "Read this sentence.",
        VoiceConfig(
            mode=VoiceMode.CLONE,
            reference_wav_path=str(reference),
            reference_text="This is the exact reference transcript.",
        ),
        tmp_path / "out.wav",
        CancellationToken(),
    )

    assert model.options is not None
    assert model.options["reference_wav_path"] == str(reference)
    assert model.options["prompt_wav_path"] == str(reference)
    assert model.options["prompt_text"] == "This is the exact reference transcript."

