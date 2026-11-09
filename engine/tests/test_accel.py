"""Which device the heavy models use: on macOS exactly what it was, on Windows the install's decision, with a way back."""
import json
import os
import sys

import pytest
import torch

from sozvon_engine import accel, platform_support


@pytest.fixture
def clean(monkeypatch):
    monkeypatch.setattr(accel, "_cpu_stages", set())


@pytest.fixture
def windows(monkeypatch, clean):
    monkeypatch.setattr(platform_support, "SYSTEM", "win32")


def probe(data, **state):
    (data / ".gpu.json").write_text(json.dumps(state), encoding="utf-8")


def cuda(monkeypatch, available=True):
    monkeypatch.setattr(torch.cuda, "is_available", lambda: available)


@pytest.mark.parametrize("available,expected", [(True, "mps"), (False, "cpu")])
def test_macos_keeps_mps_or_cpu(monkeypatch, clean, available, expected):
    monkeypatch.setattr(platform_support, "SYSTEM", "darwin")
    monkeypatch.setattr(torch.backends.mps, "is_available", lambda: available)
    assert accel.torch_device("diarize") == expected


def test_macos_failures_are_not_caught(monkeypatch, clean):
    monkeypatch.setattr(platform_support, "SYSTEM", "darwin")

    def work():
        raise RuntimeError("as before")

    with pytest.raises(RuntimeError):
        accel.with_cpu_fallback("diarize", work)


def test_no_probe_means_the_cpu_and_torch_is_not_asked(windows, monkeypatch):
    monkeypatch.setattr(torch.cuda, "is_available", lambda: pytest.fail("no reason to touch the GPU"))
    assert accel.gpu_configured() is False
    assert accel.torch_device("diarize") == "cpu"


def test_a_good_probe_means_the_gpu(windows, monkeypatch, data):
    probe(data, ok=True, device="cuda", backend="cu126")
    cuda(monkeypatch)
    assert accel.gpu_configured() is True
    assert accel.torch_device("diarize") == "cuda"


@pytest.mark.parametrize("state", [{"ok": False, "device": "cuda"}, {"ok": True, "device": "something"}, {"device": "cuda"}])
def test_a_probe_that_did_not_pass_means_the_cpu(windows, monkeypatch, data, state):
    probe(data, **state)
    cuda(monkeypatch)
    assert accel.torch_device("diarize") == "cpu"


def test_a_corrupted_probe_means_the_cpu(windows, monkeypatch, data):
    (data / ".gpu.json").write_text("{not json", encoding="utf-8")
    cuda(monkeypatch)
    assert accel.torch_device("diarize") == "cpu"


def test_a_card_that_went_away_means_the_cpu(windows, monkeypatch, data):
    probe(data, ok=True, device="cuda")
    cuda(monkeypatch, available=False)
    assert accel.torch_device("diarize") == "cpu"


def test_a_failure_on_the_gpu_reruns_that_stage_on_the_cpu_and_stays_there(windows, monkeypatch, data, capsys):
    probe(data, ok=True, device="cuda")
    cuda(monkeypatch)
    monkeypatch.setattr(torch.cuda, "empty_cache", lambda: None)
    seen = []

    def work():
        seen.append(accel.torch_device("diarize"))
        if seen[-1] == "cuda":
            raise RuntimeError("CUDA out of memory")
        return "ok"

    assert accel.with_cpu_fallback("diarize", work) == "ok"
    assert seen == ["cuda", "cpu"]
    assert "CUDA out of memory" in capsys.readouterr().err
    assert (data / ".gpu-failed").exists(), "so the card is probed again"
    assert accel.torch_device("diarize") == "cpu", "for the rest of the process"
    assert accel.torch_device("echo") == "cuda", "only this stage"


def test_a_failure_on_the_cpu_is_a_failure(windows):
    def work():
        raise RuntimeError("no")

    with pytest.raises(RuntimeError):
        accel.with_cpu_fallback("diarize", work)


def test_other_errors_are_not_treated_as_gpu_failures(windows, monkeypatch, data):
    probe(data, ok=True, device="cuda")
    cuda(monkeypatch)

    def work():
        raise KeyError("a bug")

    with pytest.raises(KeyError):
        accel.with_cpu_fallback("diarize", work)


@pytest.mark.skipif(os.name != "nt", reason="the Windows thread limit")
def test_onnx_does_not_spin_on_windows(monkeypatch):
    import onnx_asr

    from sozvon_engine import asr_onnx, config, models
    seen = {}
    fake = type("A", (), {"with_vad": lambda self, vad, **kw: self})()

    def load_model(name, path=None, quantization=None, sess_options=None, providers=None):
        seen["opts"] = sess_options
        return fake

    monkeypatch.setattr(onnx_asr, "load_model", load_model)
    monkeypatch.setattr(onnx_asr, "load_vad", lambda *a, **kw: None)
    monkeypatch.setattr(asr_onnx, "_cache", {})
    monkeypatch.setenv("SOZVON_THREADS", "3")
    assert config.load().threads == 3
    asr_onnx._load("x", next(k for k in models.MODELS if models.is_onnx(k)))
    assert seen["opts"].intra_op_num_threads == 3
    assert seen["opts"].get_session_config_entry("session.intra_op.allow_spinning") == "0"


def test_module_stays_light():
    """The MCP server imports this: torch is imported only when a device is asked for."""
    code = "import sys; from sozvon_engine import accel; sys.exit(1 if 'torch' in sys.modules else 0)"
    import subprocess
    env = {**os.environ, "PYTHONPATH": str(__import__("pathlib").Path(accel.__file__).parents[1])}
    assert subprocess.run([sys.executable, "-c", code], env=env, timeout=60).returncode == 0
