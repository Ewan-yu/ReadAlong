from pathlib import Path

from app.services.capability_service import CapabilityService


def test_capabilities_report_configuration_without_exposing_secrets(
    tmp_path: Path, monkeypatch
) -> None:
    model = tmp_path / "model"
    model.mkdir()
    token = "private-paddle-token"
    monkeypatch.setenv("VOXCPM_MODEL_PATH", str(model))
    monkeypatch.setenv("PADDLE_TOKEN", token)
    monkeypatch.setattr(CapabilityService, "_has_nvidia_gpu", staticmethod(lambda: True))

    capabilities = CapabilityService().inspect()

    by_id = {item.id: item for item in capabilities}
    assert by_id["voxcpm"].available is True
    assert by_id["paddle-ocr"].available is True
    assert token not in " ".join(item.detail for item in capabilities)


def test_voxcpm_requires_both_model_and_gpu(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("VOXCPM_MODEL_PATH", str(tmp_path / "missing"))
    monkeypatch.setattr(CapabilityService, "_has_nvidia_gpu", staticmethod(lambda: True))

    voxcpm = CapabilityService().inspect()[0]

    assert voxcpm.available is False
    assert "模型" in voxcpm.detail
