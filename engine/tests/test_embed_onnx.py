"""Speaker embeddings through ONNX Runtime on Windows, and the way back to torch."""
import hashlib
import json
import os
from pathlib import Path
from types import SimpleNamespace as NS

import numpy as np
import pytest
import torch

from sozvon_engine import diarize, embed_onnx, install, models, platform_support

ENTRY = models.MANIFEST["embedding_onnx"]


@pytest.fixture
def windows(monkeypatch):
    monkeypatch.setattr(platform_support, "SYSTEM", "win32")
    monkeypatch.setattr(embed_onnx, "_given_up", False)


def onnx_file(data) -> Path:
    path = data / "models" / ENTRY["dir"] / ENTRY["file"]
    path.parent.mkdir(parents=True)
    path.write_bytes(b"model")
    return path


def original():
    return NS(model_=NS(compute_fbank=lambda w: w * 2), sample_rate=16000, dimension=256, metric="cosine", min_num_samples=400)


def test_no_file_means_torch(windows):
    assert embed_onnx.file_path() is None


def test_macos_never_uses_it(monkeypatch, data):
    monkeypatch.setattr(platform_support, "SYSTEM", "darwin")
    monkeypatch.setattr(embed_onnx, "_given_up", False)
    onnx_file(data)
    assert embed_onnx.file_path() is None


def test_the_embedding_passes_features_and_masks_to_the_session(windows):
    seen = {}

    def run(names, feeds):
        seen.update(feeds)
        return [np.ones((2, 256))]

    step = embed_onnx.OnnxEmbedding(original(), NS(run=run))
    out = step(torch.ones(2, 1, 8000), torch.ones(2, 293))
    assert out.shape == (2, 256) and step.dimension == 256 and step.to("cpu") is step
    assert seen["fbank"].dtype == np.float32 and float(seen["fbank"].max()) == 2.0 and seen["weights"].shape == (2, 293)


def test_a_file_that_does_not_load_leaves_torch_in_place(windows, data, capsys):
    onnx_file(data)
    pipeline = NS(_embedding=original())
    embed_onnx.install_on(pipeline)
    assert not embed_onnx.is_active(pipeline), "still the torch step"
    assert embed_onnx.file_path() is None, "not tried again in this process"
    assert capsys.readouterr().err


class FakePipeline:
    """Counts its runs; fails on the ONNX path while `broken`."""

    def __init__(self, active, broken=True):
        self._embedding = embed_onnx.OnnxEmbedding(original(), NS(run=None)) if active else original()
        self.broken, self.active = broken, active
        self.runs = 0

    def __call__(self, wave):
        self.runs += 1
        if self.active and self.broken:
            raise ValueError("ONNX failed half way")
        return NS(speaker_diarization=NS(itertracks=lambda yield_label: [(NS(start=0.0, end=1.0), None, "A")]))


def test_a_failure_during_the_run_starts_over_on_torch(windows, monkeypatch, capsys):
    pipelines = [FakePipeline(active=True), FakePipeline(active=False)]
    loaded = iter(pipelines)
    monkeypatch.setattr(diarize, "load_pipeline", lambda: _pick(loaded))
    monkeypatch.setattr(diarize, "load_waveform", lambda path: "wave")
    assert diarize.run("x") == [(0.0, 1.0, "A")]
    assert [p.runs for p in pipelines] == [1, 1], "from nothing, on a pipeline of its own"
    assert embed_onnx.file_path() is None
    assert "ONNX failed" in capsys.readouterr().err


def _pick(loaded):
    pipeline = next(loaded)
    diarize._pipeline = pipeline
    return pipeline


def test_a_failure_on_torch_stays_a_failure(windows, monkeypatch):
    class Failing:
        _embedding = original()

        def __call__(self, wave):
            raise KeyError("a bug")

    monkeypatch.setattr(diarize, "load_pipeline", lambda: setattr(diarize, "_pipeline", Failing()) or diarize._pipeline)
    monkeypatch.setattr(diarize, "load_waveform", lambda path: "wave")
    with pytest.raises(KeyError):
        diarize.run("x")


def good_fetch(url, dest):
    Path(dest).write_bytes(b"model")


def entry_for(monkeypatch, content=b"model"):
    monkeypatch.setitem(models.MANIFEST, "embedding_onnx", {**ENTRY, "sha256": hashlib.sha256(content).hexdigest()})


def test_install_fetches_and_checks_the_file_with_its_notice(windows, monkeypatch, tmp_path):
    monkeypatch.setattr(platform_support, "replace_file", os.replace)  # SYSTEM is faked: platform_win32 only imports on Windows
    entry_for(monkeypatch)
    install.ensure_embedding_onnx(tmp_path, good_fetch)
    d = tmp_path / "models" / ENTRY["dir"]
    assert (d / ENTRY["file"]).read_bytes() == b"model"
    notice = (d / "NOTICE.txt").read_text(encoding="utf-8")
    assert "CC BY 4.0" in notice and "WeSpeaker" in notice and "ONNX" in notice


def test_install_without_the_published_file_says_nothing(windows, tmp_path, capfd):
    def missing(url, dest):
        raise OSError("404")

    install.ensure_embedding_onnx(tmp_path, missing)
    assert not (tmp_path / "models" / ENTRY["dir"] / ENTRY["file"]).exists()
    captured = capfd.readouterr()
    assert captured.out == "" and captured.err == ""


def test_install_refuses_a_file_with_the_wrong_hash(windows, monkeypatch, tmp_path):
    entry_for(monkeypatch, b"another")
    install.ensure_embedding_onnx(tmp_path, good_fetch)
    assert not (tmp_path / "models" / ENTRY["dir"] / ENTRY["file"]).exists()


def test_macos_install_does_not_touch_it(monkeypatch, tmp_path):
    monkeypatch.setattr(platform_support, "SYSTEM", "darwin")
    install.ensure_embedding_onnx(tmp_path, lambda url, dest: pytest.fail("not on macOS"))


@pytest.mark.slow
def test_same_turns_as_torch(data, monkeypatch, tmp_path):
    """On the pinned pyannote: ONNX and torch give the same diarization. Needs an installed engine with the file."""
    from conftest import installed_engine
    engine = installed_engine() or (Path(os.environ["SOZVON_TEST_ENGINE"]) if os.environ.get("SOZVON_TEST_ENGINE") else None)
    if engine is None or not (engine / "models" / ENTRY["dir"] / ENTRY["file"]).exists():
        pytest.skip("no installed engine with the ONNX embedding file")
    audio = os.environ.get("SOZVON_TEST_DIARIZE_AUDIO")
    if not audio:
        pytest.skip("SOZVON_TEST_DIARIZE_AUDIO: a call track to compare on")
    monkeypatch.setenv("SOZVON_DATA_DIR", str(engine))
    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    monkeypatch.setenv("HF_HUB_CACHE", str(engine / "hf-cache"))
    monkeypatch.setattr(embed_onnx, "_given_up", False)
    monkeypatch.setattr(diarize, "_pipeline", None)
    onnx = diarize.run(audio)
    monkeypatch.setattr(embed_onnx, "_given_up", True)
    monkeypatch.setattr(diarize, "_pipeline", None)
    torch_turns = diarize.run(audio)
    assert json.dumps(onnx) == json.dumps(torch_turns)
