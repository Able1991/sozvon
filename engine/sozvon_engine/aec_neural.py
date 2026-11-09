"""Neural echo suppression next to the classic canceller (aec.py): LocalVQE v1.2, Apache-2.0.

The classic stage and this one run in parallel on the same input: the model hears the raised mic, not the
classic output, plus the far-end reference aligned by the delay track, and removes the speaker echo that the
linear filter cannot (on a laptop speaker that is most of it). It also reduces noise and reverberation, which
is why its output is only used where the far end is active (with a hold for the echo tail): where the far end
is silent the classic output is kept sample for sample, so the user and people in the room are not processed
at all. While the far end talks the model does process the voices next to the mic, and it can reduce a voice
much quieter than the speakers.

Runs on Apple Silicon (MPS, CPU fallback), streams the call in 30 s pieces, each one warmed up on the audio
before it. Weights are one download (models.json, key "aec"). Anything going wrong leaves the classic output:
this stage can only make it better.
"""
import hashlib
import os
from pathlib import Path

import numpy as np

from . import accel, models, paths, platform_support

SR = 16000
CHUNK = 30 * SR            # model input length; memory stays bounded for any call length
OVERLAP = SR               # chunks overlap by 1 s and are cross-faded
FRAME = 160                # 10 ms: resolution of the far-end activity gate
HOLD = 0.35                # seconds the gate stays open after the far end stops (echo tail)
PRE = 0.03                 # seconds it opens before the far end starts
LEAD = int(0.048 * SR)     # the model expects the echo slightly after the reference
GAIN = 2.3                 # this checkpoint outputs about -7 dB relative to its input, at any input level
BLOCK = 256
WARMUP = 3 * SR            # samples of the audio before a chunk the model hears first, then forgets: the model
                           # runs from a clean state each chunk, and a cold model lets the echo through
MAX_RISE = 4.0             # gated output energy allowed over the input (+6 dB): beyond it the model has gone wrong
QUIET_ENERGY = 1e-8        # per-sample energy treated as silence by the level check


def weights_state() -> tuple[Path | None, str]:
    """(the checkpoint, "ok") when it is usable, else (None, why not): off, no_weights, bad_weights."""
    entry = models.MANIFEST.get("aec")
    if not entry:
        return None, "no_weights"
    if os.environ.get("SOZVON_NEURAL_AEC", "1") == "0":
        return None, "off"
    d = paths.data_dir() / "models" / entry["dir"]
    f = d / entry["files"][0]
    if not (d / models.COMPLETE).exists() or not f.is_file():
        return None, "no_weights"
    h = hashlib.sha256()
    with open(f, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    if h.hexdigest() == entry["sha256"]:
        return f, "ok"
    (d / models.COMPLETE).unlink(missing_ok=True)  # the launch retry fetches it again only without this marker
    return None, "bad_weights"


def weights_path() -> Path | None:
    """The checkpoint if the download is complete and intact, else None."""
    return weights_state()[0]


class _Model:
    """Load the checkpoint. forward(mic, ref) -> enhanced waveform (numpy, same length as the input)."""

    def __init__(self, path: Path):
        import torch

        from .localvqe.model import LocalVQE
        if platform_support.SYSTEM == "win32":
            accel.apply_thread_limit()
        # weights_only: no pickled code runs, and the file was checked against its SHA-256 before this.
        ck = torch.load(path, map_location="cpu", weights_only=True)  # nosemgrep: trailofbits.python.pickles-in-pytorch.pickles-in-pytorch
        cfg = ck["model_config"]
        # The checkpoint stores only its channel widths; these four come from the upstream manifest for v1.2.
        net = LocalVQE(arch_version=3, dmax=64, align_hidden=32, power_law_c=0.3,
                       mic_channels=cfg["mic_channels"], far_channels=cfg["far_channels"],
                       kernel_size=cfg["kernel_size"], bottleneck_hidden=cfg["bottleneck_hidden"],
                       n_freqs=cfg["n_freqs"]).eval()
        net.load_state_dict(ck["model_state_dict"])
        net.align.fold_temperature()
        self.device = accel.torch_device("echo")
        self.net = net.to(self.device)
        self.torch = torch

    def forward(self, mic: np.ndarray, ref: np.ndarray) -> np.ndarray:
        t = self.torch
        with t.no_grad():
            m = t.from_numpy(mic.astype(np.float32)).unsqueeze(0).to(self.device)
            r = t.from_numpy(ref.astype(np.float32)).unsqueeze(0).to(self.device)
            out = self.net(m, r)
            if out.ndim == 4:
                out = self.net.decoder(out, length=m.shape[1])
            return out[0].cpu().numpy().astype(np.float64)


def _aligned(read, track, a: int, n: int) -> np.ndarray:
    """Reference for mic samples a..a+n, moved by the delay track (the mic lags it by LEAD samples)."""
    out = np.zeros(n)
    for k in range(0, n, BLOCK):
        m = min(BLOCK, n - k)
        out[k:k + m] = read(a + k - (track.at(a + k) - LEAD), m)
    return out


def activity(read, track, total: int, thr: float) -> np.ndarray:
    """Per 10 ms frame: is the far end (or its echo tail) in the mic here. Sequential, 1 byte per frame."""
    n = total // FRAME
    act = np.zeros(n, bool)
    for i in range(n):
        x = _aligned(read, track, i * FRAME, FRAME)
        act[i] = float(x @ x) / FRAME > thr * thr
    hold, pre = int(HOLD * SR / FRAME), int(PRE * SR / FRAME)
    out = np.convolve(act.astype(np.float64), np.ones(hold), "full")[:n] > 0
    if pre and n > pre:
        out[:-pre] |= act[pre:]
    return out


def _gate(act: np.ndarray, a: int, n: int) -> np.ndarray:
    """Sample gate for a..a+n from the frame activity, with short fades."""
    i0, i1 = a // FRAME, (a + n) // FRAME + 2
    frames = act[max(0, i0 - 3):i1 + 3].astype(np.float64)
    smooth = np.convolve(frames, np.ones(3) / 3, "same")[min(i0, 3):]
    g = np.repeat(smooth, FRAME)[a % FRAME:a % FRAME + n]
    return np.concatenate([g, np.full(n - len(g), g[-1] if len(g) else 0.0)])


def _network(model, mic, ref, track, act, a: int, n: int) -> np.ndarray:
    """The model's output for mic samples a..a+n, level restored, warmed up on the audio before a. Raises when the
    output is not finite or is louder than the mic where it would be used: the caller falls back to the classic output."""
    lead = min(a, WARMUP)
    y = np.asarray(model.forward(mic.read(a - lead, n + lead), _aligned(ref.read, track, a - lead, n + lead)))
    if not np.isfinite(y).all():
        raise ValueError("non-finite output from the network")
    y = GAIN * y[lead:lead + n]
    if len(y) < n:
        y = np.concatenate([y, np.zeros(n - len(y))])
    g = _gate(act, a, n)
    m = mic.read(a, n)
    if float(np.sum((g * y) ** 2)) > MAX_RISE * float(np.sum((g * m) ** 2)) + n * QUIET_ENERGY:
        raise ValueError("network output level above the mic")
    return y


def enhance(mic, ref, classic, out: Path, track, thr: float, model) -> None:
    """mic, ref, classic: aec._Reader of the input mic, the reference, the classic output; out: aec._Writer path.
    Writes the final track. Far-silent stretches are the classic output, unchanged."""
    from . import aec
    total = classic.n
    act = activity(ref.read, track, total, thr)
    w = aec._Writer(out)
    try:
        fade = np.linspace(0.0, 1.0, OVERLAP)
        tail = None                                   # neural output of the overlap with the next chunk
        a = 0
        while a < total:
            n = min(CHUNK, total - a)
            active = bool(act[a // FRAME:(a + n) // FRAME + 1].any())
            base = classic.read(a, n)
            y = _network(model, mic, ref, track, act, a, n) if active else base.copy()
            if tail is not None:
                k = min(OVERLAP, n)
                y[:k] = tail[:k] * (1 - fade[:k]) + y[:k] * fade[:k]
            final = a + n >= total
            take = n if final else n - OVERLAP
            g = _gate(act, a, take)
            w.write(g * y[:take] + (1 - g) * base[:take])
            if final:
                break
            tail = y[take:].copy()
            a += take
    finally:
        w.close()


def apply(mic_path: Path, ref_path: Path, classic: Path, track, thr: float) -> str:
    """Replace the classic output `classic` with the neural one. -> "ok", or why not, then the file is untouched:
    "off", "no_weights", "bad_weights", "error: <what happened>" (any failure). `track` is the delay track from aec."""
    from . import aec
    tmp = classic.with_name(classic.stem + ".nn.wav")
    m = r = c = model = None
    try:
        weights, state = weights_state()
        if weights is None:
            return state
        m, r, c = aec._Reader(mic_path), aec._Reader(ref_path), aec._Reader(classic)

        def work():
            nonlocal model
            model = _Model(weights)
            enhance(m, r, c, tmp, track, thr, model)

        def drop():
            nonlocal model
            model = None

        accel.with_cpu_fallback("echo", work, drop=drop)
        for f in (m, r, c):
            f.close()
        m = r = c = None
        platform_support.replace_file(tmp, classic)
        return "ok"
    except Exception as ex:  # noqa: BLE001  the classic output stays
        return f"error: {ex!r}"[:300]
    finally:
        for f in (m, r, c):
            if f is not None:
                f.close()
        tmp.unlink(missing_ok=True)
        model = None   # before the GPU cache is cleared, or it still holds the weights
        _free_gpu()


def _free_gpu() -> None:
    """The rest of the run (Whisper, pyannote) needs the GPU memory the model held."""
    accel.release()
