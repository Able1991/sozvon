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


def test_quiet_track_is_raised_loud_one_left(tmp_path):
    import wave
    import numpy as np
    from sozvon_engine.pipeline import tracks

    def make(name, amp):
        t = np.arange(16000 * 2) / 16000
        x = (amp * np.sin(2 * np.pi * 220 * t) * 32767).astype("<i2")
        p = tmp_path / name
        with wave.open(str(p), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(x.tobytes())
        return p

    quiet = make("quiet.wav", 0.01)          # about -40 dBFS, like a mic at a third of its input volume
    g = tracks.boost(quiet)
    assert 25 < g <= tracks.MAX_GAIN
    assert tracks.loudness(tracks.audio.decode(quiet)) > 0.25
    assert tracks.active_seconds(quiet) > 1.5, "speech is detected after the boost"
    loud = make("loud.wav", 0.5)
    assert tracks.boost(loud) == 1.0
    silent = make("silent.wav", 0.0)
    assert tracks.boost(silent) == 1.0, "digital silence is not amplified"


def test_clean_mic_saved_and_removed(tmp_path):
    import wave
    import numpy as np
    from sozvon_engine.pipeline import tracks
    wav = tmp_path / "mic.wav"
    x = (0.3 * np.sin(2 * np.pi * 220 * np.arange(16000) / 16000) * 32767).astype("<i2")
    with wave.open(str(wav), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(x.tobytes())
    tracks.save_clean_mic(tmp_path, wav, print)
    out = tmp_path / tracks.CLEAN_MIC
    assert out.is_file() and out.stat().st_size > 1000
    assert not list(tmp_path.glob(".*.tmp.m4a")), "no temp file left"
    tracks.save_clean_mic(tmp_path, None, print)
    assert not out.exists(), "a transcription without improvement drops the old copy"
