"""Track analysis: where there is speech and where system audio dropped out."""
import wave
from pathlib import Path

import numpy as np

from sozvon_engine.pipeline import tracks as pc

SR = 16000


def write_wav(path: Path, x: np.ndarray) -> Path:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())
    return path


def noise(seconds, amp=0.2, seed=0):
    return np.random.default_rng(seed).uniform(-amp, amp, int(seconds * SR)).astype(np.float32)


def test_dead_span_detected(tmp_path):
    x = np.concatenate([noise(10), np.zeros(90 * SR, np.float32), noise(10, seed=1)])
    spans = pc.dead_spans(write_wav(tmp_path / "s.wav", x))
    assert len(spans) == 1
    s, e = spans[0]
    assert abs(s - 10) < 0.5 and abs(e - 100) < 0.5


def test_short_silence_is_not_dead(tmp_path):
    # A 30 s pause from the other side is not a capture failure.
    x = np.concatenate([noise(10), np.zeros(30 * SR, np.float32), noise(10, seed=1)])
    assert pc.dead_spans(write_wav(tmp_path / "s.wav", x)) == []


def test_quiet_room_noise_is_not_dead(tmp_path):
    # Quiet background, but not digital zero: capture works.
    x = noise(120, amp=0.001)
    assert pc.dead_spans(write_wav(tmp_path / "s.wav", x)) == []


def test_active_seconds(tmp_path):
    x = np.concatenate([np.zeros(5 * SR, np.float32), noise(3, amp=0.3)])
    act = pc.active_seconds(write_wav(tmp_path / "a.wav", x))
    assert 2.5 < act < 3.5
