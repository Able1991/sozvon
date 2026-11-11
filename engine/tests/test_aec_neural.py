"""The neural echo suppressor around the classic canceller (fake models, plus one tiny real LocalVQE: no weights)."""
import hashlib
import weakref

import numpy as np
import pytest

from sozvon_engine import aec, aec_neural, models

from test_aec import SR, write, read, jumping_call

GAIN = 2.3          # the level this checkpoint is restored by: a literal, not aec_neural.GAIN, so a change shows


class Fake:
    """Stands in for the network: a fixed output level, so the tests can see which path produced a sample."""

    def __init__(self, value=0.1):
        self.value = value
        self.calls = 0

    def forward(self, mic, ref):
        self.calls += 1
        return np.full(len(mic), self.value)


class Recording(Fake):
    """A fake that keeps what the network was given."""

    def __init__(self, value=0.1):
        super().__init__(value)
        self.seen = []

    def forward(self, mic, ref):
        self.seen.append((mic.copy(), ref.copy()))
        return super().forward(mic, ref)


class PerCall(Fake):
    """Each call answers its own value: the two sides of a seam can be told apart."""

    def __init__(self, values):
        super().__init__()
        self.values = values

    def forward(self, mic, ref):
        v = self.values[self.calls]
        self.calls += 1
        return np.full(len(mic), v)


class ColdStart(Fake):
    """A burst for the first 0.5 s of every call, like a cold model before it locks on, then the steady level."""

    def forward(self, mic, ref):
        self.calls += 1
        y = np.full(len(mic), self.value)
        y[:SR // 2] = 1.0
        return y


def far_with_gap(secs=70):
    """Far end plays in [0, 10) and [40, 60), silent otherwise."""
    far = np.zeros(secs * SR)
    rng = np.random.default_rng(0)
    for a, b in ((0, 10), (40, 60)):
        far[a * SR:b * SR] = 0.2 * rng.standard_normal((b - a) * SR)
    return far


def ints(path):
    """A wav as raw 16-bit samples."""
    import wave
    with wave.open(str(path), "rb") as w:
        return np.frombuffer(w.readframes(w.getnframes()), "<i2")


def loud_mic(n):
    """A raised mic loud enough to pass the output level check, whatever the fake answers."""
    return 0.5 * np.sin(2 * np.pi * 300 * np.arange(n) / SR)


def run(tmp_path, far, classic, model, mic=None, track=None):
    track = track or aec.DelayTrack(np.array([0]), np.array([800]))
    m = write(tmp_path / "m.wav", loud_mic(len(far)) if mic is None else mic)
    r = write(tmp_path / "r.wav", far)
    c = write(tmp_path / "c.wav", classic)
    out = tmp_path / "out.wav"
    readers = [aec._Reader(p) for p in (m, r, c)]
    try:
        aec_neural.enhance(readers[0], readers[1], readers[2], out, track, 1e-3, model)
    finally:
        for x in readers:
            x.close()
    return read(out)


def test_far_silence_keeps_the_classic_output_exactly(tmp_path):
    far = far_with_gap()
    classic = 0.05 * np.sin(2 * np.pi * 300 * np.arange(len(far)) / SR)
    run(tmp_path, far, classic, Fake(0.1))
    a, b = ints(tmp_path / "c.wav"), ints(tmp_path / "out.wav")
    assert len(a) == len(b)
    assert np.array_equal(a[20 * SR:38 * SR], b[20 * SR:38 * SR]), "not sample-identical while the far end is silent"


def test_far_end_active_uses_the_network_output_at_the_restored_level(tmp_path):
    far = far_with_gap()
    classic = 0.05 * np.sin(2 * np.pi * 300 * np.arange(len(far)) / SR)
    out = run(tmp_path, far, classic, Fake(0.1))
    assert np.abs(out[45 * SR:55 * SR] - 0.1 * GAIN).max() < 1e-2


def test_the_model_hears_the_raw_mic_and_the_aligned_reference(tmp_path):
    far = far_with_gap()
    classic = 0.01 * np.ones(len(far))
    mic = 0.3 * np.random.default_rng(0).standard_normal(len(far))
    track = aec.DelayTrack(np.array([0, 20 * SR]), np.array([800, 1600]))
    model = Recording()
    run(tmp_path, far, classic, model, mic=mic, track=track)
    rm, rr = aec._Reader(tmp_path / "m.wav"), aec._Reader(tmp_path / "r.wav")
    try:
        seen_mic, seen_ref = model.seen[1]               # the second chunk: starts after the first delay jump
        a = 29 * SR - aec_neural.WARMUP
        n = len(seen_mic)
        assert np.array_equal(seen_mic, rm.read(a, n)), "the model must hear the raw raised mic, not the classic output"
        assert np.array_equal(seen_ref, aec_neural._aligned(rr.read, track, a, n)), "the reference must follow the delay track"
        assert not np.array_equal(seen_ref, rr.read(a, n))
    finally:
        rm.close()
        rr.close()


def test_a_cold_model_never_reaches_the_seam(tmp_path):
    """The burst of a cold start lands in audio that is thrown away, not in the far-end talk after the seam."""
    secs = 62
    far = 0.2 * np.random.default_rng(0).standard_normal(secs * SR)
    far[:2 * SR] = 0                                       # the very start of the call has nothing before it
    classic = np.zeros(secs * SR)
    model = ColdStart(0.1)
    out = run(tmp_path, far, classic, model)
    # steady network level right across the first seam and the rest of the chunk (hold fades only at the start)
    assert np.abs(out[3 * SR:30 * SR] - 0.1 * GAIN).max() < 1e-2
    assert np.abs(out[30 * SR:45 * SR] - 0.1 * GAIN).max() < 1e-2, "a cold start reached the audio after the seam"


def test_every_later_chunk_warms_up_before_the_part_that_is_kept(tmp_path):
    secs = 70
    far = 0.2 * np.random.default_rng(0).standard_normal(secs * SR)
    model = Recording()
    run(tmp_path, far, np.zeros(secs * SR), model)
    a, b = len(model.seen[0][0]), len(model.seen[1][0])
    assert a == 30 * SR
    assert b == 30 * SR + aec_neural.WARMUP, "the second chunk starts WARMUP before the seam"
    assert aec_neural.WARMUP >= 2 * SR


def test_chunks_cross_fade_at_the_seam(tmp_path):
    secs = 45
    far = 0.2 * np.random.default_rng(0).standard_normal(secs * SR)
    classic = np.zeros(secs * SR)
    out = run(tmp_path, far, classic, PerCall([0.04, 0.08, 0.08]))
    mid = int(29.5 * SR)
    assert out[mid] == pytest.approx(GAIN * 0.06, abs=4e-3), "halfway through the overlap: half of each side"
    assert out[int(29.02 * SR)] == pytest.approx(GAIN * 0.04, abs=8e-3)
    assert out[int(29.98 * SR)] == pytest.approx(GAIN * 0.08, abs=8e-3)
    fade = out[int(29 * SR):int(30 * SR)]
    assert np.all(np.diff(fade[::40]) > 0), "a smooth ramp, not a step"


def test_the_gate_keeps_the_echo_tail_and_opens_just_before_the_far_end(tmp_path):
    secs = 40
    far = np.zeros(secs * SR)
    far[10 * SR:20 * SR] = 0.2 * np.random.default_rng(0).standard_normal(10 * SR)
    classic = np.full(secs * SR, 0.02)
    out = run(tmp_path, far, classic, Fake(0.1))
    net, cls = 0.1 * GAIN, 0.02
    assert out[int(9.90 * SR)] == pytest.approx(cls, abs=3e-3), "closed well before the far end"
    assert cls + 0.02 < out[int(9.975 * SR)] < net - 0.02, "already opening 30 ms before the far end starts"
    assert out[int(10.02 * SR)] == pytest.approx(net, abs=3e-3)
    assert out[int(20.30 * SR)] == pytest.approx(net, abs=3e-3), "held for the echo tail after the far end stops"
    assert out[int(20.42 * SR)] == pytest.approx(cls, abs=3e-3), "closed again after the hold"


def test_a_chunk_without_far_end_is_not_sent_to_the_network(tmp_path):
    far = far_with_gap(secs=90)
    far[40 * SR:60 * SR] = 0
    model = Fake()
    run(tmp_path, far, np.zeros(len(far)), model)
    # the far end only plays in the first 10 s: one 30 s chunk, the rest never reach the model
    assert model.calls == 1


def test_reference_follows_the_delay_track():
    track = aec.DelayTrack(np.array([0, 16000]), np.array([100, 1100]))
    seen = []

    def read_at(start, n):
        seen.append(start)
        return np.zeros(n)
    aec_neural._aligned(read_at, track, 15000, 2000)
    lead = aec_neural.LEAD
    assert seen[0] == 15000 - 100 + lead
    assert seen[-1] > 16000 - 1100 + lead - aec_neural.BLOCK


def _install(tmp_path, monkeypatch, content=b"weights"):
    monkeypatch.setenv("SOZVON_DATA_DIR", str(tmp_path))
    entry = {"repo": "x", "revision": "r", "dir": "aec", "files": ["w.pt"],
             "sha256": hashlib.sha256(b"weights").hexdigest()}
    monkeypatch.setitem(models.MANIFEST, "aec", entry)
    d = tmp_path / "models" / "aec"
    d.mkdir(parents=True)
    (d / "w.pt").write_bytes(content)
    (d / models.COMPLETE).write_text("r\n")
    return d / "w.pt"


def test_weights_are_found_only_when_intact(tmp_path, monkeypatch):
    f = _install(tmp_path, monkeypatch)
    assert aec_neural.weights_path() == f
    f.write_bytes(b"broken")
    assert aec_neural.weights_path() is None


def test_weights_missing_or_turned_off(tmp_path, monkeypatch):
    monkeypatch.setenv("SOZVON_DATA_DIR", str(tmp_path))
    monkeypatch.setitem(models.MANIFEST, "aec", {"repo": "x", "revision": "r", "dir": "aec", "files": ["w.pt"], "sha256": "0"})
    assert aec_neural.weights_path() is None
    tmp2 = tmp_path / "other"
    tmp2.mkdir()
    f = _install(tmp2, monkeypatch)
    monkeypatch.setenv("SOZVON_NEURAL_AEC", "0")
    assert aec_neural.weights_path() is None
    monkeypatch.delenv("SOZVON_NEURAL_AEC")
    assert aec_neural.weights_path() == f


def classic_output(tmp_path, m, r):
    """What the classic stage alone writes for this mic and reference."""
    out = tmp_path / "classic-stage.wav"
    aec._cancel(m, r, out, None, 60.0, 0.0)
    return out.read_bytes()


def test_cancel_writes_the_network_output_over_the_classic_one(tmp_path, monkeypatch):
    far, mic, pieces, m, r = jumping_call(tmp_path)

    class Quiet(Fake):
        def __init__(self, path):
            super().__init__(0.005)
    monkeypatch.setattr(aec_neural, "_Model", Quiet)
    monkeypatch.setattr(aec_neural, "weights_state", lambda: (tmp_path / "w.pt", "ok"))
    rep = aec.cancel(m, r)
    assert rep.applied and rep.neural and rep.neural_reason == "ok"
    out = read(m)
    # 3 s to skip the warm-up of the model, the network path owns every sample here
    assert np.abs(out[3 * SR:15 * SR] - 0.005 * GAIN).max() < 1e-3


def test_cancel_without_the_network_is_the_classic_result(tmp_path, monkeypatch):
    far, mic, pieces, m, r = jumping_call(tmp_path)
    expected = classic_output(tmp_path, m, r)
    monkeypatch.setattr(aec_neural, "apply", lambda *a: "no_weights")
    rep = aec.cancel(m, r)
    assert rep.applied and not rep.neural and rep.neural_reason == "no_weights"
    assert m.read_bytes() == expected


def test_cancel_not_applied_never_runs_the_network(tmp_path, monkeypatch):
    """Headphones: nothing to remove, nothing is sent to the model and the mic stays byte for byte."""
    from test_aec import speech
    near = speech(40, 1, [(2, 38)])
    far = speech(40, 2, [(1, 39)])
    m = write(tmp_path / "mic.wav", near + 1e-3 * np.random.default_rng(0).standard_normal(len(near)))
    before = m.read_bytes()
    monkeypatch.setattr(aec_neural, "apply", lambda *a: pytest.fail("the network ran on a clean mic"))
    rep = aec.cancel(m, write(tmp_path / "system.wav", far))
    assert not rep.applied and not rep.neural and m.read_bytes() == before


class Boom(Fake):
    def __init__(self, path):
        super().__init__()

    def forward(self, a, b):
        raise RuntimeError("out of memory")


def test_a_failing_model_leaves_the_classic_output(tmp_path, monkeypatch):
    far, mic, pieces, m, r = jumping_call(tmp_path)
    expected = classic_output(tmp_path, m, r)
    monkeypatch.setattr(aec_neural, "_Model", Boom)
    monkeypatch.setattr(aec_neural, "weights_state", lambda: (tmp_path / "w.pt", "ok"))
    rep = aec.cancel(m, r)
    assert rep.applied and not rep.neural
    assert rep.neural_reason.startswith("error") and "out of memory" in rep.neural_reason
    assert m.read_bytes() == expected, "the classic output must be what is left, byte for byte"
    assert not list(tmp_path.glob("*.nn.wav"))


def call_files(tmp_path, seconds=62):
    """Mic, reference and classic output wav files that apply() can work on; the classic bytes for comparing."""
    far = 0.2 * np.random.default_rng(0).standard_normal(seconds * SR)
    m = write(tmp_path / "m.wav", loud_mic(seconds * SR))
    r = write(tmp_path / "r.wav", far)
    c = write(tmp_path / "c.wav", 0.02 * np.ones(seconds * SR))
    return m, r, c, c.read_bytes()


TRACK = aec.DelayTrack(np.array([0]), np.array([800]))


def use_model(monkeypatch, tmp_path, cls):
    monkeypatch.setattr(aec_neural, "_Model", cls)
    monkeypatch.setattr(aec_neural, "weights_state", lambda: (tmp_path / "w.pt", "ok"))


class Loud(Fake):
    def __init__(self, path):
        super().__init__(5.0)


class Good(Fake):
    def __init__(self, path):
        super().__init__(0.05)


@pytest.mark.parametrize("bad", [np.nan, np.inf, -np.inf])
def test_non_finite_output_keeps_the_classic_file(tmp_path, monkeypatch, bad):
    m, r, c, before = call_files(tmp_path)

    class Glitch(Fake):
        def __init__(self, path):
            super().__init__()

        def forward(self, mic, ref):
            y = np.full(len(mic), 0.1)
            y[1000] = bad
            return y
    use_model(monkeypatch, tmp_path, Glitch)
    why = aec_neural.apply(m, r, c, TRACK, 1e-3)
    assert why.startswith("error")
    assert c.read_bytes() == before
    assert not list(tmp_path.glob("*.nn.wav"))


def test_a_failure_in_a_later_chunk_keeps_the_whole_classic_file(tmp_path, monkeypatch):
    m, r, c, before = call_files(tmp_path)

    class SecondChunkGlitch(Fake):
        def __init__(self, path):
            super().__init__(0.05)

        def forward(self, mic, ref):
            y = super().forward(mic, ref)
            return y if self.calls == 1 else y * np.nan
    use_model(monkeypatch, tmp_path, SecondChunkGlitch)
    assert aec_neural.apply(m, r, c, TRACK, 1e-3).startswith("error")
    assert c.read_bytes() == before, "nothing written before the failure may reach the classic file"
    assert not list(tmp_path.glob("*.nn.wav"))


def test_output_far_louder_than_the_mic_is_refused(tmp_path, monkeypatch):
    m, r, c, before = call_files(tmp_path)
    use_model(monkeypatch, tmp_path, Loud)
    why = aec_neural.apply(m, r, c, TRACK, 1e-3)
    assert why.startswith("error") and "level" in why
    assert c.read_bytes() == before


def test_a_normal_chunk_passes_the_level_check_and_replaces_the_file(tmp_path, monkeypatch):
    m, r, c, before = call_files(tmp_path)
    use_model(monkeypatch, tmp_path, Good)
    assert aec_neural.apply(m, r, c, TRACK, 1e-3) == "ok"
    assert c.read_bytes() != before
    assert np.abs(read(c)[35 * SR:45 * SR] - 0.05 * GAIN).max() < 1e-2


@pytest.mark.parametrize("env,content,why", [("0", b"weights", "off"), (None, None, "no_weights"), (None, b"broken", "bad_weights")])
def test_apply_says_why_it_did_not_deliver(tmp_path, monkeypatch, env, content, why):
    if env is not None:
        monkeypatch.setenv("SOZVON_NEURAL_AEC", env)
    else:
        monkeypatch.delenv("SOZVON_NEURAL_AEC", raising=False)
    if content is not None:
        _install(tmp_path, monkeypatch, content)
    else:
        monkeypatch.setenv("SOZVON_DATA_DIR", str(tmp_path))
    m, r, c, before = call_files(tmp_path, 3)
    assert aec_neural.apply(m, r, c, TRACK, 1e-3) == why
    assert c.read_bytes() == before


def test_a_damaged_model_is_no_longer_marked_complete(tmp_path, monkeypatch):
    """The launch retry looks only at .complete: a file that went bad later must be fetched again."""
    monkeypatch.delenv("SOZVON_NEURAL_AEC", raising=False)
    _install(tmp_path, monkeypatch, b"broken")
    d = tmp_path / "models" / models.MANIFEST["aec"]["dir"]
    assert (d / models.COMPLETE).exists()
    assert aec_neural.weights_state() == (None, "bad_weights")
    assert not (d / models.COMPLETE).exists()


def test_a_read_error_on_the_weights_falls_back_with_the_reason(tmp_path, monkeypatch):
    def denied():
        raise PermissionError("denied")
    m, r, c, before = call_files(tmp_path, 3)
    monkeypatch.setattr(aec_neural, "weights_state", denied)
    why = aec_neural.apply(m, r, c, TRACK, 1e-3)
    assert why.startswith("error") and "denied" in why
    assert c.read_bytes() == before


def test_the_model_is_released_before_the_gpu_is_cleared(tmp_path, monkeypatch):
    m, r, c, _ = call_files(tmp_path, 3)
    made = []

    class Tracked(Fake):
        def __init__(self, path):
            super().__init__(0.05)
            made.append(weakref.ref(self))
    monkeypatch.setattr(aec_neural, "_Model", Tracked)
    monkeypatch.setattr(aec_neural, "weights_state", lambda: (tmp_path / "w.pt", "ok"))
    alive = []
    monkeypatch.setattr(aec_neural, "_free_gpu", lambda: alive.append(made[0]() is not None))
    aec_neural.apply(m, r, c, TRACK, 1e-3)
    assert alive == [False], "_free_gpu ran while the model was still referenced"


def test_a_real_tiny_model_runs_through_load_and_forward(tmp_path):
    """The vendored package and _Model as CI sees them: no download, a generated checkpoint of a few KB."""
    import torch
    from sozvon_engine.localvqe.model import LocalVQE
    cfg = {"mic_channels": [2, 4, 4, 4, 4, 4], "far_channels": [2, 4, 4], "kernel_size": [4, 4], "bottleneck_hidden": 8,
           "n_freqs": 256}
    net = LocalVQE(arch_version=3, dmax=64, align_hidden=32, power_law_c=0.3, **cfg)
    path = tmp_path / "tiny.pt"
    torch.save({"model_config": cfg, "model_state_dict": net.state_dict()}, path)
    model = aec_neural._Model(path)
    rng = np.random.default_rng(1)
    mic, ref = 0.05 * rng.standard_normal(SR), 0.05 * rng.standard_normal(SR)
    y = model.forward(mic, ref)
    assert len(y) == SR and np.isfinite(y).all()


REAL_WIDTHS = {"mic_channels": [2, 32, 40, 40, 40, 40], "far_channels": [2, 32, 40], "kernel_size": [4, 4],
               "bottleneck_hidden": 162, "n_freqs": 256}      # the published v1.2 checkpoint


@pytest.mark.parametrize("frames", [3, 40])        # shorter and longer than the delay window
def test_lean_alignment_matches_the_vendored_block(frames):
    """The alignment the model runs with is the vendored one, computed without a copy of the reference per delay."""
    import torch
    from sozvon_engine.localvqe.align import AlignBlock
    torch.manual_seed(0)
    block = AlignBlock(8, 6, dmax=16, temperature=0.5).eval()
    mic, ref = torch.randn(2, 8, frames, 9), torch.randn(2, 8, frames, 9)
    with torch.no_grad():
        want, want_delay = AlignBlock.forward(block, mic, ref, return_delay=True)
        got, got_delay = aec_neural.lean_align(block, mic, ref, return_delay=True)
        assert got.shape == want.shape and got_delay.shape == want_delay.shape
        assert torch.allclose(got, want, atol=1e-5)
        assert torch.allclose(got_delay, want_delay, atol=1e-6)
        assert torch.allclose(aec_neural.lean_align(block, mic, ref), want, atol=1e-5)


def test_the_loaded_model_aligns_without_the_per_delay_copies(tmp_path, monkeypatch):
    import torch
    from sozvon_engine.localvqe.align import AlignBlock
    from sozvon_engine.localvqe.model import LocalVQE
    cfg = {"mic_channels": [2, 4, 4, 4, 4, 4], "far_channels": [2, 4, 4], "kernel_size": [4, 4], "bottleneck_hidden": 8,
           "n_freqs": 256}
    net = LocalVQE(arch_version=3, dmax=64, align_hidden=32, power_law_c=0.3, **cfg)
    path = tmp_path / "tiny.pt"
    torch.save({"model_config": cfg, "model_state_dict": net.state_dict()}, path)
    rng = np.random.default_rng(2)
    mic, ref = 0.05 * rng.standard_normal(SR), 0.05 * rng.standard_normal(SR)
    net.eval().align.fold_temperature()
    with torch.no_grad():
        want = net(torch.from_numpy(mic.astype(np.float32))[None], torch.from_numpy(ref.astype(np.float32))[None])
        if want.ndim == 4:
            want = net.decoder(want, length=SR)
    model = aec_neural._Model(path)

    def vendored(*a, **kw):
        raise AssertionError("the vendored alignment ran: it copies the reference once per delay")
    monkeypatch.setattr(AlignBlock, "forward", vendored)
    got = model.forward(mic, ref)
    assert np.allclose(got, want[0].numpy(), atol=1e-5)


PEAK_SCRIPT = """
import resource, sys
import numpy as np, torch
from sozvon_engine import aec_neural
from sozvon_engine.localvqe.model import LocalVQE
cfg = %r
torch.manual_seed(0)
net = LocalVQE(arch_version=3, dmax=64, align_hidden=32, power_law_c=0.3, **cfg)
torch.save({"model_config": cfg, "model_state_dict": net.state_dict()}, sys.argv[1])
del net
model = aec_neural._Model(sys.argv[1])
model.device = "cpu"                       # process memory is only a fair measure on the CPU
model.net.to("cpu")
n = aec_neural.CHUNK + aec_neural.WARMUP   # the longest piece the engine ever sends
rng = np.random.default_rng(0)
y = model.forward(0.05 * rng.standard_normal(n), 0.05 * rng.standard_normal(n))
assert len(y) == n
peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
print(peak if sys.platform == "darwin" else peak * 1024)
"""


def test_one_piece_of_a_call_fits_in_two_and_a_half_gigabytes(tmp_path):
    """A 33 s piece at the real model widths. With a copy of the reference per delay it took 3.4 GB on the CPU and
    9.3 GB on the GPU, for every call longer than half a minute."""
    import subprocess
    import sys
    from pathlib import Path
    engine = Path(aec_neural.__file__).resolve().parent.parent
    res = subprocess.run([sys.executable, "-c", PEAK_SCRIPT % (REAL_WIDTHS,), str(tmp_path / "real.pt")],
                         cwd=engine, capture_output=True, text=True, timeout=600)
    assert res.returncode == 0, res.stderr[-2000:]
    peak = int(res.stdout.strip().splitlines()[-1])
    assert peak < 2.5 * 2**30, f"peak {peak / 2**30:.2f} GB"


class Pickled:
    """A checkpoint with an object that a weights-only load must refuse."""

    def __reduce__(self):
        return (print, ("code would have run here",))


def test_the_checkpoint_loads_weights_only(tmp_path):
    import torch
    from sozvon_engine.localvqe.model import LocalVQE
    cfg = {"mic_channels": [2, 4, 4, 4, 4, 4], "far_channels": [2, 4, 4], "kernel_size": [4, 4], "bottleneck_hidden": 8,
           "n_freqs": 256}
    net = LocalVQE(arch_version=3, dmax=64, align_hidden=32, power_law_c=0.3, **cfg)
    path = tmp_path / "evil.pt"
    torch.save({"model_config": cfg, "model_state_dict": net.state_dict(), "extra": Pickled()}, path)
    with pytest.raises(Exception, match="(?i)unsafe|global|unpickl"):
        aec_neural._Model(path)


@pytest.mark.slow
def test_real_weights_run_and_keep_the_length(tmp_path, monkeypatch):
    """Needs SOZVON_TEST_LOCALVQE: a local copy of the checkpoint named in models.json. It is placed in a temporary
    data dir, so the manifest entry, the hash check and the load path are the ones an install uses."""
    import os
    import shutil
    from pathlib import Path
    p = os.environ.get("SOZVON_TEST_LOCALVQE")
    if not p or not Path(p).exists():
        pytest.skip("SOZVON_TEST_LOCALVQE: no local checkpoint")
    entry = models.MANIFEST["aec"]
    d = tmp_path / "models" / entry["dir"]
    d.mkdir(parents=True)
    shutil.copy(p, d / entry["files"][0])
    (d / models.COMPLETE).write_text("done")
    monkeypatch.setenv("SOZVON_DATA_DIR", str(tmp_path))
    weights, state = aec_neural.weights_state()
    assert state == "ok", f"{p} is not the checkpoint named in models.json"
    model = aec_neural._Model(weights)
    rng = np.random.default_rng(1)
    far = 0.1 * rng.standard_normal(2 * SR)
    y = model.forward(0.05 * far, far)
    assert len(y) == 2 * SR and np.isfinite(y).all()
