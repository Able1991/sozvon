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
        return 300.0 * real(self, e, y)
    monkeypatch.setattr(aec._Mdf, "suppress", louder)
    before = call["mic_wav"].read_bytes()
    rep = aec.cancel(call["mic_wav"], call["sys_wav"])
    assert not rep.applied and rep.reason == "diverged"
    assert call["mic_wav"].read_bytes() == before


def jumping_call(tmp_path, nonlinear=False):
    """The far end plays; its echo reaches the mic with a delay that jumps in steps, as a real call does."""
    secs = 60
    far = speech(secs, 2, [(0.5, 59.5)])
    pieces = [(0, 20, 0.030), (20, 40, 0.085), (40, 60, 0.015)]
    echo = np.zeros_like(far)
    for a, b, d in pieces:
        n = int(d * SR)
        h = np.zeros(n + 1200)
        h[n] = 0.6
        h[n + 1:] = 0.15 * np.random.default_rng(3).standard_normal(1199) * np.exp(-np.arange(1, 1200) / 300)
        seg = np.convolve(far, h)[:len(far)]
        echo[int(a * SR):int(b * SR)] = seg[int(a * SR):int(b * SR)]
    if nonlinear:      # a small speaker driven hard
        echo = np.tanh(6 * echo) / 6
    noise = 3e-4 * np.random.default_rng(5).standard_normal(len(far))
    mic = echo + noise
    return far, mic, pieces, write(tmp_path / "m.wav", mic), write(tmp_path / "r.wav", far)


def test_delay_track_follows_jumps(tmp_path):
    far, mic, pieces, m, r = jumping_call(tmp_path)
    rm, rr = aec._Reader(m), aec._Reader(r)
    try:
        track = aec.estimate_delay(rm, rr, 1e-3)
    finally:
        rm.close()
        rr.close()
    for a, b, d in pieces:
        assert abs(track.at(int((a + b) / 2 * SR)) / SR - d) <= 0.003


def test_the_far_end_history_moves_with_a_delay_step(tmp_path):
    """Right after a step the filter must see the reference at the new delay, not 256 ms of the old alignment."""
    far = speech(30, 2, [(0.2, 29.8)])
    mic = 0.3 * far
    m, r = write(tmp_path / "m.wav", mic), write(tmp_path / "r.wav", far)
    rm, rr = aec._Reader(m), aec._Reader(r)
    step = 1000 * aec.B                                  # 16 s, inside the far-end speech
    track = aec.DelayTrack(np.array([0, step]), np.array([480, 1280]))
    c = aec._Mdf(1e-3)
    try:
        k = step // aec.B
        aec._pass(c, rm, rr, track, k - 40, k + 1)
        dl = 1280 - aec.MARGIN
        for j in range(1, aec.P):
            expected = np.fft.rfft(rr.read(step - (j + 1) * aec.B - dl, aec.NFFT))
            assert np.allclose(c.X[j], expected, atol=1e-6), f"partition {j} still has the old delay"
    finally:
        rm.close()
        rr.close()


def test_delay_pieces_match_the_plain_definition_on_random_tracks():
    """Running-median version gives the same pieces as recomputing the median for every point."""
    rng = np.random.default_rng(0)
    for trial in range(20):
        lags, pts, lag = [], [], 400
        for i in range(600):
            r = rng.random()
            lag += 0 if r < 0.97 else int(rng.integers(-80, 80))
            lags.append(lag + (int(rng.integers(-30, 30)) if rng.random() < 0.05 else 0))
        pts = [(i * 8000, v) for i, v in enumerate(lags)]
        got = aec._pieces(pts)
        assert got == _pieces_by_definition(pts)


def _pieces_by_definition(points):
    """The original quadratic definition of aec._pieces."""
    tol = aec.TRACK_TOL * SR / 1000
    runs, cur, pending = [], [points[0]], []
    for p in points[1:]:
        if abs(p[1] - np.median([q[1] for q in cur])) <= tol:
            cur.append(p)
            pending = []
            continue
        if pending and abs(p[1] - np.median([q[1] for q in pending])) <= tol:
            pending.append(p)
        else:
            pending = [p]
        if len(pending) >= aec.TRACK_MIN:
            runs.append(cur)
            cur, pending = pending, []
    runs.append(cur)
    return [r for r in runs if len(r) >= aec.TRACK_MIN]


def test_delay_pieces_stay_fast_on_a_long_call():
    import time
    pts = [(i * 8000, 500 + (i % 3 == 0)) for i in range(4 * 7200)]        # four hours of 0.5 s frames, one delay
    t0 = time.monotonic()
    aec._pieces(pts)
    assert time.monotonic() - t0 < 1.0


def test_the_report_gives_the_delivered_echo_reduction(tmp_path, monkeypatch):
    """When the network output replaces the classic one, erle_db describes what is in the file."""
    from sozvon_engine import aec_neural
    far, mic, pieces, m, r = jumping_call(tmp_path)
    classic = aec.cancel(write(tmp_path / "m2.wav", mic), r, warmup=60.0)
    def quiet(mic_path, ref_path, c, track, thr):
        c.write_bytes(_scale_wav(c.read_bytes(), 0.01))
        return "ok"
    monkeypatch.setattr(aec_neural, "apply", quiet)
    rep = aec.cancel(m, r)
    assert rep.neural
    assert rep.erle_db > classic.erle_db + 30, (rep.erle_db, classic.erle_db)


def test_measuring_the_delivered_file_reads_it_in_pieces(tmp_path, monkeypatch):
    """A 4 h call must not be loaded whole just to report a number."""
    import wave
    from sozvon_engine import aec_neural
    far, mic, pieces, m, r = jumping_call(tmp_path)
    monkeypatch.setattr(aec_neural, "apply", lambda *a: "ok")
    asked = []
    real = aec._report_delivered
    original = wave.Wave_read.readframes

    def spy(self, n):
        asked.append(n)
        return original(self, n)

    def measured(*a):
        monkeypatch.setattr(wave.Wave_read, "readframes", spy)
        try:
            real(*a)
        finally:
            monkeypatch.setattr(wave.Wave_read, "readframes", original)

    monkeypatch.setattr(aec, "_report_delivered", measured)
    assert aec.cancel(m, r).neural
    assert asked and max(asked) <= aec.CHUNK


def test_a_failed_measurement_keeps_the_delivered_file(tmp_path, monkeypatch):
    """The number is a report; the cleaned audio is the product."""
    from sozvon_engine import aec_neural
    far, mic, pieces, m, r = jumping_call(tmp_path)
    before = m.read_bytes()

    def quiet(mic_path, ref_path, c, track, thr):
        c.write_bytes(_scale_wav(c.read_bytes(), 0.01))
        return "ok"

    def fails(*a):
        raise MemoryError

    monkeypatch.setattr(aec_neural, "apply", quiet)
    monkeypatch.setattr(aec, "_report_delivered", fails)
    rep = aec.cancel(m, r)
    assert rep.neural
    assert m.read_bytes() != before
    assert np.abs(read(m)).max() < 0.05


def _scale_wav(data, k):
    import io
    r = wave.open(io.BytesIO(data))
    y = (np.frombuffer(r.readframes(r.getnframes()), "<i2") * k).astype("<i2")
    out = io.BytesIO()
    w = wave.open(out, "wb")
    w.setnchannels(1), w.setsampwidth(2), w.setframerate(SR), w.writeframes(y.tobytes())
    w.close()
    return out.getvalue()


def test_echo_is_removed_on_both_sides_of_a_delay_jump(tmp_path):
    far, mic, pieces, m, r = jumping_call(tmp_path)
    rep = aec.cancel(m, r)
    assert rep.applied
    out = read(m)
    for a, b, _ in pieces:
        span = [(a + 3, b - 2)]
        assert db(energy(mic, span), energy(out, span)) >= 15


def test_nonlinear_echo_is_suppressed_more_than_the_linear_filter_can(tmp_path):
    far, mic, pieces, m, r = jumping_call(tmp_path, nonlinear=True)
    rep = aec.cancel(m, r)
    assert rep.applied
    out = read(m)
    span = [(a + 3, b - 2) for a, b, _ in pieces]
    assert db(energy(mic, span), energy(out, span)) >= 20


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
            track = aec.estimate_delay(rm, rr, 1e-3)
        finally:
            rm.close()
            rr.close()
        assert abs(track.at(5 * SR) / SR - delay) <= 0.002 and len(track.delays) == 1


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


def neural_prepare(monkeypatch, tmp_path, why, marker=False):
    calls, out, lines = fake_prepare(monkeypatch, tmp_path, {"mic": 30.0, "system": 40.0})
    monkeypatch.setenv("SOZVON_DATA_DIR", str(tmp_path))
    if marker:
        (tmp_path / ".no-echo-model").touch()
    monkeypatch.setattr(aec, "cancel", lambda mic, ref: aec.Report(True, "ok", delay_ms=42.0, erle_db=18.0, neural=False, neural_reason=why))
    warnings, lines = [], []
    pc.prepare({k: tmp_path / f"{k}.m4a" for k in ("mic", "system")}, {}, tmp_path, lines.append,
               warn=lambda step, err: warnings.append((step, err)))
    return lines, warnings


@pytest.mark.parametrize("why,word", [("off", "выключ"), ("no_weights", "скача"), ("bad_weights", "поврежд"), ("error: boom", "boom")])
def test_a_neural_stage_that_did_not_deliver_logs_one_line_with_the_reason(monkeypatch, tmp_path, why, word):
    lines, _ = neural_prepare(monkeypatch, tmp_path, why)
    assert sum(word in s for s in lines) == 1, lines


def test_a_neural_stage_that_delivered_logs_no_failure(monkeypatch, tmp_path):
    lines, warnings = neural_prepare(monkeypatch, tmp_path, "")
    assert warnings == [] and not any("нейро" in s and "пропущ" in s.lower() for s in lines)


@pytest.mark.parametrize("why", ["error: boom", "bad_weights"])
def test_a_real_failure_goes_into_the_call_warnings(monkeypatch, tmp_path, why):
    _, warnings = neural_prepare(monkeypatch, tmp_path, why)
    assert warnings == [("echo", why)]


def test_weights_turned_off_or_not_yet_downloaded_are_not_warned_about(monkeypatch, tmp_path):
    assert neural_prepare(monkeypatch, tmp_path, "off")[1] == []
    assert neural_prepare(monkeypatch, tmp_path, "no_weights")[1] == []


def test_a_failed_download_warns_once_then_only_logs(monkeypatch, tmp_path):
    _, first = neural_prepare(monkeypatch, tmp_path, "no_weights", marker=True)
    assert first == [("echo", "no_weights")]
    assert not (tmp_path / ".no-echo-model").exists(), "reported: the marker is gone"
    lines, second = neural_prepare(monkeypatch, tmp_path, "no_weights")
    assert second == [] and any("скача" in s for s in lines)


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


def test_cleanup_removes_work_folder(tmp_path):
    d = tmp_path / "call"
    (d / ".work").mkdir(parents=True)
    for name in ("mic.wav", "system.wav", "mic.aec.wav"):
        (d / ".work" / name).write_bytes(b"x")
    (d / "mic.m4a").write_bytes(b"x")
    pc.cleanup(d)
    assert sorted(p.name for p in d.iterdir()) == ["mic.m4a"]


def test_cleanup_removes_leftovers_of_older_versions(tmp_path):
    """Before .work the wavs lay in the call folder itself: a crash of that version left them."""
    d = tmp_path / "call"
    d.mkdir()
    for name in ("mic.wav", "system.wav", "mic.aec.wav", "mic.m4a"):
        (d / name).write_bytes(b"x")
    pc.cleanup(d)
    assert sorted(p.name for p in d.iterdir()) == ["mic.m4a"]


def test_prepare_keeps_working_files_in_work_folder(monkeypatch, tmp_path):
    (tmp_path / ".work").mkdir()
    (tmp_path / ".work" / "stale.wav").write_bytes(b"x")  # left by a killed run
    calls, out, _ = fake_prepare(monkeypatch, tmp_path, {"mic": 30.0, "system": 40.0})
    assert {p.parent for p in out.values()} == {tmp_path / ".work"}
    assert sorted(p.name for p in (tmp_path / ".work").iterdir()) == ["mic.wav", "system.wav"]
    assert not list(tmp_path.glob("*.wav"))
