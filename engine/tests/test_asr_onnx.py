"""GigaAM / Parakeet via onnx-asr (without the models themselves)."""
from types import SimpleNamespace

import numpy as np

from sozvon_engine import asr_onnx, models


def test_known_models():
    assert asr_onnx.is_onnx("gigaam") and asr_onnx.is_onnx("parakeet")
    assert not asr_onnx.is_onnx("turbo")


def test_is_downloaded(tmp_path):
    assert not models.is_downloaded(tmp_path, "gigaam")
    d = models.model_dir(tmp_path, "gigaam")
    d.mkdir(parents=True)
    for f in models.MODELS["gigaam"]["files"]:
        (d / f).write_text("x")
    assert not models.is_downloaded(tmp_path, "gigaam"), "without the VAD it is not ready"
    models.vad_dir(tmp_path).mkdir(parents=True)
    for f in models.VAD["files"]:
        (models.vad_dir(tmp_path) / f).write_text("x")
    assert models.is_downloaded(tmp_path, "gigaam")


def test_transcribe_keeps_text_segments(monkeypatch, tmp_path):
    class Fake:
        def recognize(self, audio, sample_rate):
            assert sample_rate == 16000
            return [SimpleNamespace(start=0.5, end=2.0, text=" Привет "),
                    SimpleNamespace(start=3.0, end=3.5, text="  ")]
    monkeypatch.setitem(asr_onnx._cache, "gigaam", Fake())
    out = asr_onnx.transcribe(tmp_path, "gigaam", np.zeros(16000, np.float32))
    assert out == [(0.5, 2.0, "Привет")]
