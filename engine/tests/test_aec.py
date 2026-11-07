"""Offline echo cancellation of the microphone on synthetic signals (no models, no ffmpeg)."""
import wave

import numpy as np
import pytest

from sozvon_engine import aec
from sozvon_engine.pipeline import tracks as pc

SR = aec.SR
DELAY = 0.040


def speech(seconds: float, seed: int, spans) -> np.ndarray:
    """Speech-like signal: voiced harmonics with a gliding pitch plus shaped noise, syllable envelope, only in spans."""
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    t = np.arange(n) / SR
    f0 = 120 + 40 * np.sin(2 * np.pi * 0.3 * t + seed) + 15 * np.sin(2 * np.pi * 2.1 * t)
    ph = 2 * np.pi * np.cumsum(f0) / SR
    voiced = sum(np.sin(h * ph) / h for h in range(1, 20))
    noise = np.convolve(rng.standard_normal(n), np.exp(-np.arange(40) / 8), "same") * 0.3
    syll = 0.5 + 0.5 * np.sin(2 * np.pi * (3.5 + seed % 3 * 0.4) * t) ** 2
    gate = np.zeros(n)
    for s, e in spans:
        gate[int(s * SR):int(e * SR)] = 1
    gate = np.convolve(gate, np.hanning(801) / np.hanning(801).sum(), "same")
    x = (voiced + noise) * syll * gate
    return 0.15 * x / (np.abs(x).max() + 1e-9)


def room(seed: int = 7) -> np.ndarray:
    rng = np.random.default_rng(seed)
    d = int(DELAY * SR)
    h = np.zeros(d + 2400)
    h[d] = 1.0
    tail = np.arange(1, 2400)
    h[d + 1:] = rng.standard_normal(len(tail)) * 0.4 * np.exp(-tail / 350)
    return h


def write(path, x):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
    return path


def read(path):
    with wave.open(str(path), "rb") as w:
        return np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float64) / 32768


# Timeline (s): far end alone, me alone, both, far end alone, me alone, both.
SECONDS = 72.0
FAR = [(0, 14), (24, 34), (38, 50), (60, 70)]
NEAR = [(14, 22), (26, 32), (50, 58), (62, 68)]
FAR_ONLY = [(2, 13), (40, 49)]
NEAR_ONLY = [(15, 21), (52, 57)]
DOUBLE = [(27, 31), (63, 67)]


def energy(x, spans):
    return sum(float((x[int(s * SR):int(e * SR)] ** 2).sum()) for s, e in spans)


def db(a, b):
    return 10 * np.log10(a / b)


@pytest.fixture
def call(tmp_path):
    near = speech(SECONDS, 1, NEAR)
    far = speech(SECONDS, 2, FAR)
    echo = 0.5 * np.convolve(far, room())[:len(far)]
    noise = 1e-3 * np.random.default_rng(3).standard_normal(len(far))
    mic = near + echo + noise
    return {"near": near, "far": far, "mic": mic,
            "mic_wav": write(tmp_path / "mic.wav", mic), "sys_wav": write(tmp_path / "system.wav", far)}


def test_removes_echo_and_keeps_my_voice(call):
    rep = aec.cancel(call["mic_wav"], call["sys_wav"])
    assert rep.applied and rep.reason == "ok"
    assert abs(rep.delay_ms - DELAY * 1000) <= 2
    out = read(call["mic_wav"])
    mic = call["mic"]
    assert len(out) == len(mic)
    erle = db(energy(mic, FAR_ONLY), energy(out, FAR_ONLY))
    assert erle >= 15, erle
    assert rep.erle_db >= 10
    assert abs(db(energy(out, NEAR_ONLY), energy(mic, NEAR_ONLY))) < 1.5

    near = call["near"]

    def corr(x):
        idx = np.concatenate([np.arange(int(s * SR), int(e * SR)) for s, e in DOUBLE])
        return float(np.corrcoef(x[idx], near[idx])[0, 1])
    assert corr(out) > corr(mic) + 0.05, (corr(out), corr(mic))


def test_silent_far_end_leaves_mic_alone(tmp_path):
    near = speech(30, 1, [(2, 28)])
    mic = write(tmp_path / "mic.wav", near)
    before = mic.read_bytes()
    rep = aec.cancel(mic, write(tmp_path / "system.wav", np.zeros_like(near)))
    assert not rep.applied
    assert mic.read_bytes() == before


def test_no_echo_in_mic_is_skipped(tmp_path):
    """Headphones: the far end talks, but the mic hears only me."""
    near = speech(40, 1, [(2, 38)])
    far = speech(40, 2, [(1, 39)])
    mic = write(tmp_path / "mic.wav", near + 1e-3 * np.random.default_rng(0).standard_normal(len(near)))
    before = mic.read_bytes()
    rep = aec.cancel(mic, write(tmp_path / "system.wav", far))
    assert not rep.applied and rep.reason in ("no_delay", "no_echo")
    assert mic.read_bytes() == before


def test_unrelated_reference_falls_back(tmp_path, call):
    """Forced delay and a reference that has nothing to do with the mic: the original is kept."""
    other = speech(SECONDS, 5, FAR)
    ref = write(tmp_path / "other.wav", other)
    before = call["mic_wav"].read_bytes()
    rep = aec.cancel(call["mic_wav"], ref, delay=0.04)
    assert not rep.applied and rep.reason in ("no_echo", "diverged")
    assert call["mic_wav"].read_bytes() == before
    assert not list(tmp_path.glob("*.aec.wav"))


def test_diverged_filter_falls_back(call, monkeypatch):
    """Output louder than the input where the far end plays: the original is kept."""
    real = aec._Mdf.suppress

    def louder(self, e, y):
        return 30.0 * real(self, e, y)
    monkeypatch.setattr(aec._Mdf, "suppress", louder)
    before = call["mic_wav"].read_bytes()
    rep = aec.cancel(call["mic_wav"], call["sys_wav"])
    assert not rep.applied and rep.reason == "diverged"
    assert call["mic_wav"].read_bytes() == before


def test_delay_estimate_follows_the_echo(tmp_path):
    far = speech(40, 2, [(1, 39)])
    near = speech(40, 1, [(10, 15)])
    for delay in (0.012, 0.150, 0.310):
        h = np.zeros(int(delay * SR) + 1)
        h[-1] = 0.4
        mic = near + np.convolve(far, h)[:len(far)] + 1e-3 * np.random.default_rng(1).standard_normal(len(far))
        m, r = write(tmp_path / "m.wav", mic), write(tmp_path / "r.wav", far)
        rm, rr = aec._Reader(m), aec._Reader(r)
        try:
            rms = aec._frame_rms(rr)
            a, b = aec.estimate_delay(rm, rr, rms, 1e-3)
        finally:
            rm.close()
            rr.close()
        assert abs(a / SR - delay) <= 0.002 and b == 0.0


# ---------------------------------------------------------------- prepare


def fake_prepare(monkeypatch, tmp_path, speech_sec: dict, env=None):
    calls = []
    monkeypatch.setattr(pc.audio, "to_wav", lambda src, dst, delay=0.0: dst.write_bytes(b"x") and dst)
    monkeypatch.setattr(pc, "boost", lambda wav: 1.0)
    monkeypatch.setattr(pc, "active_seconds", lambda wav: speech_sec[wav.stem])
    monkeypatch.setattr(aec, "cancel", lambda mic, ref: calls.append((mic.name, ref.name)) or aec.Report(
        True, "ok", delay_ms=42.0, erle_db=18.0))
    if env is not None:
        monkeypatch.setenv("SOZVON_AEC", env)
    else:
        monkeypatch.delenv("SOZVON_AEC", raising=False)
    files = {k: tmp_path / f"{k}.m4a" for k in speech_sec}
    lines = []
    out = pc.prepare(files, {}, tmp_path, lines.append)
    return calls, out, lines


def test_prepare_cancels_echo_when_both_tracks_speak(monkeypatch, tmp_path):
    calls, out, lines = fake_prepare(monkeypatch, tmp_path, {"mic": 30.0, "system": 40.0})
    assert calls == [("mic.wav", "system.wav")]
    assert set(out) == {"mic", "system"}
    assert any("18 дБ" in s and "42 мс" in s for s in lines)


@pytest.mark.parametrize("sec", [{"mic": 30.0, "system": 0.2}, {"mic": 0.2, "system": 30.0}, {"mic": 30.0}])
def test_prepare_skips_echo_cancel_without_both_tracks(monkeypatch, tmp_path, sec):
    calls, _, _ = fake_prepare(monkeypatch, tmp_path, sec)
    assert calls == []


def test_prepare_echo_cancel_off_by_env(monkeypatch, tmp_path):
    calls, out, _ = fake_prepare(monkeypatch, tmp_path, {"mic": 30.0, "system": 40.0}, env="0")
    assert calls == [] and set(out) == {"mic", "system"}


def test_prepare_survives_echo_cancel_error(monkeypatch, tmp_path):
    def boom(mic, ref):
        raise ValueError("bad wav")
    calls, out, lines = fake_prepare(monkeypatch, tmp_path, {"mic": 30.0, "system": 40.0})
    monkeypatch.setattr(aec, "cancel", boom)
    lines = []
    out = pc.prepare({k: tmp_path / f"{k}.m4a" for k in ("mic", "system")}, {}, tmp_path, lines.append)
    assert set(out) == {"mic", "system"}
    assert any("bad wav" in s for s in lines)


def test_error_mid_way_leaves_no_temp_file(call, monkeypatch):
    """An exception while the cancelled mic is being written: the half-written mic.aec.wav is removed."""
    real = aec._Writer
    seen = []

    class Failing:
        def __init__(self, path):
            self.w = real(path)
            seen.append(path)

        def write(self, x):
            self.w.write(x)
            assert seen[0].exists()
            raise RuntimeError("disk full")

        def close(self):
            self.w.close()
    monkeypatch.setattr(aec, "_Writer", Failing)
    before = call["mic_wav"].read_bytes()
    with pytest.raises(RuntimeError):
        aec.cancel(call["mic_wav"], call["sys_wav"], delay=DELAY)
    assert seen and not list(call["mic_wav"].parent.glob("*.aec.wav"))
    assert call["mic_wav"].read_bytes() == before


def test_cleanup_removes_aec_leftovers(tmp_path):
    d = tmp_path / "call"
    d.mkdir()
    for name in ("mic.wav", "system.wav", "mic.aec.wav", "mic.m4a"):
        (d / name).write_bytes(b"x")
    pc.cleanup(d)
    assert sorted(p.name for p in d.iterdir()) == ["mic.m4a"]
