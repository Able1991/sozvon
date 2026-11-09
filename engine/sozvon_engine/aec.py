"""Offline acoustic echo cancellation of the microphone track.

Without headphones the microphone hears the speakers: the other side's voices come back in mic.wav,
delayed by the device and the air (tens to hundreds of milliseconds) and colored by the room. system.wav
is exactly what the speakers played, so it is a perfect far-end reference.

Steps, all streaming over 16 kHz mono 16-bit wav files (memory stays bounded for any call length):
1. Delay track: GCC-PHAT between the mic and the reference on 1 s frames (every 0.5 s while the far end
   plays), grouped into pieces of constant delay. The echo delay of a real call is not one number: the
   system and microphone captures slip against each other in steps of tens of milliseconds, by up to a few
   hundred over a call, and the filter window has to follow it.
2. A partitioned-block frequency-domain adaptive filter (MDF, as in Speex): 256-sample blocks, 512-point
   FFTs (50% overlap-save), 16 partitions (256 ms of echo path after the bulk delay). NLMS with a
   per-bin learning rate from the estimated echo leakage (Valin 2007): when the near end talks the
   error is large next to the echo estimate and adaptation almost stops. Two filters: the background one
   adapts, the foreground one produces the output and only takes the background weights when they are
   clearly better; a background filter ruined by double talk is reset from the foreground.
3. A residual echo suppressor. On a laptop speaker a large part of the echo cannot be predicted from the
   reference by any linear filter (measured on a real call: the best one, of any length, removes about
   9 dB; AAC coding and simple speaker clipping do not explain the rest). The suppressor
   learns per frequency how much residual there is for a given echo estimate while only the far end
   plays, then applies a Wiener-like gain from it, never below -20 dB. Bins where the near end is louder
   than that are left alone, so speech over the far end stays.
4. Safety: if the output in far-end regions is louder than the input, or almost no echo was removed,
   the original microphone is kept.
"""
import bisect
import math
import os
import time
import wave
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

SR = 16000
B = 256                    # block (hop) in samples, 16 ms
NFFT = 2 * B
K = B + 1                  # rfft bins
P = 16                     # partitions: 16 * 256 = 4096 taps = 256 ms after the bulk delay
MARGIN = 160               # the filter starts 10 ms before the estimated delay (taps before the main peak)
MAX_DELAY = 0.6            # delay search range, seconds: the echo comes after the reference, but the
MIN_DELAY = -0.3           # captures of the two tracks slip against each other by up to a few hundred ms
FLOOR = 0.1                # residual suppressor gain floor (-20 dB)
RES_ALPHA = 2.0            # residual suppressor over-subtraction
RES_RATE = 0.96            # per-frame smoothing of the residual/echo statistics while only the far end plays
RES_MIN = 0.02             # smallest residual/echo ratio per bin
RES_FAR_ONLY = 1.8         # mic energy up to this times the echo estimate: nothing but the far end is heard
CHUNK = 30 * SR            # read and write in 30 s pieces

GCC_FRAME = 2 * SR         # 2 s frames for the far-end activity (threshold, warm-up minute)
TRACK_FRAME = SR           # delay track: 1 s frames...
TRACK_HOP = SR // 2        # ...every 0.5 s while the far end plays
TRACK_SCORE = 12.0         # peak height over the robust noise level of the correlation
TRACK_TOL = 5.0            # ms: frames this close to a piece's median belong to it
TRACK_MIN = 3              # frames needed to believe in a new piece of delay


@dataclass
class Report:
    applied: bool
    reason: str                       # ok, no_far, no_delay, no_echo, diverged
    delay_ms: float | None = None     # median delay over the call
    drift_ms: float = 0.0             # delay change from the first piece of the track to the last
    jumps: int = 0                    # how many times the delay changed along the call
    neural: bool = False              # the neural residual suppressor (aec_neural.py) was applied
    neural_reason: str = ""           # ok; or why the classic output stayed: off, no_weights, bad_weights, error: ...
    erle_db: float | None = None      # echo reduction in far-end-only regions
    gain_db: float | None = None      # output/input energy over all far-end regions (negative: quieter)
    seconds: float = 0.0              # processing time
    levels: dict = field(default_factory=dict)  # rms dBFS before/after in far-only and near-only regions


class _Reader:
    """Random access to a 16-bit mono wav with a cached window; zeros outside the file."""

    def __init__(self, path: Path):
        self.w = wave.open(str(path), "rb")
        if self.w.getnchannels() != 1 or self.w.getsampwidth() != 2 or self.w.getframerate() != SR:
            self.w.close()
            raise ValueError(f"{path}: expected 16 kHz mono 16-bit wav")
        self.n = self.w.getnframes()
        self.buf = np.zeros(0, np.float32)
        self.b0 = 0

    def read(self, start: int, n: int) -> np.ndarray:
        out = np.zeros(n, np.float64)
        lo, hi = max(start, 0), min(start + n, self.n)
        if lo >= hi:
            return out
        if not (self.b0 <= lo and hi <= self.b0 + len(self.buf)):
            end = min(self.n, max(hi, lo + CHUNK))
            self.w.setpos(lo)
            self.buf = np.frombuffer(self.w.readframes(end - lo), "<i2").astype(np.float32) / 32768.0
            self.b0 = lo
        out[lo - start:hi - start] = self.buf[lo - self.b0:hi - self.b0]
        return out

    def close(self):
        self.w.close()


class _Writer:
    def __init__(self, path: Path):
        self.w = wave.open(str(path), "wb")
        self.w.setnchannels(1)
        self.w.setsampwidth(2)
        self.w.setframerate(SR)
        self.parts, self.size = [], 0

    def write(self, x: np.ndarray):
        self.parts.append(x)
        self.size += len(x)
        if self.size >= CHUNK:
            self.flush()

    def flush(self):
        if self.parts:
            y = np.rint(np.concatenate(self.parts) * 32768)        # the reader divides by 32768: exact round trip
            self.w.writeframes(np.clip(y, -32768, 32767).astype("<i2").tobytes())
            self.parts, self.size = [], 0

    def close(self):
        self.flush()
        self.w.close()


# ---------------------------------------------------------------- delay


def _frame_rms(r: _Reader) -> np.ndarray:
    """RMS of every GCC frame of the reference (one sequential pass)."""
    n = r.n // GCC_FRAME
    out = np.zeros(n)
    for i in range(n):
        x = r.read(i * GCC_FRAME, GCC_FRAME)
        out[i] = math.sqrt(float(x @ x) / GCC_FRAME)
    return out


@dataclass
class DelayTrack:
    """Echo delay along the call, piecewise constant, in samples (positive: the mic lags the reference)."""
    starts: np.ndarray    # first sample of each piece, ascending
    delays: np.ndarray

    def at(self, n: int) -> int:
        return int(self.delays[max(int(np.searchsorted(self.starts, n, "right")) - 1, 0)])


def _gcc(mic: np.ndarray, ref: np.ndarray, win: np.ndarray, band: np.ndarray) -> tuple[int, float]:
    """GCC-PHAT of one frame. -> (lag in samples where the mic lags the reference, peak score)."""
    nfft = 2 * TRACK_FRAME
    c = np.fft.rfft(mic * win, nfft) * np.conj(np.fft.rfft(ref * win, nfft))
    full = np.fft.irfft(np.where(band, c / (np.abs(c) + 1e-20), 0), nfft)
    neg, maxlag = int(-MIN_DELAY * SR), int(MAX_DELAY * SR)
    cc = np.concatenate([full[-neg:], full[:maxlag + 1]])   # lags -neg..maxlag
    k = int(np.argmax(cc))
    rest = np.concatenate([cc[:max(0, k - 32)], cc[k + 33:]])
    med = float(np.median(rest))
    sigma = 1.4826 * float(np.median(np.abs(rest - med))) + 1e-12
    return k - neg, (float(cc[k]) - med) / sigma


def _median(sorted_values: list) -> float:
    n = len(sorted_values)
    return float(sorted_values[n // 2]) if n % 2 else (sorted_values[n // 2 - 1] + sorted_values[n // 2]) / 2


def _pieces(points: list) -> list:
    """Group (sample, lag) points into runs of nearly constant lag; a lone outlier does not end a run."""
    tol = TRACK_TOL * SR / 1000
    runs, cur, pending = [], [points[0]], []
    lags = [points[0][1]]                # lags of cur, kept sorted: the median is one list access
    for p in points[1:]:
        if abs(p[1] - _median(lags)) <= tol:
            cur.append(p)
            bisect.insort(lags, p[1])
            pending = []
            continue
        if pending and abs(p[1] - np.median([q[1] for q in pending])) <= tol:
            pending.append(p)
        else:
            pending = [p]
        if len(pending) >= TRACK_MIN:
            runs.append(cur)
            cur, pending = pending, []
            lags = sorted(q[1] for q in cur)
    runs.append(cur)
    return [r for r in runs if len(r) >= TRACK_MIN]


def estimate_delay(m: _Reader, r: _Reader, thr: float) -> DelayTrack | None:
    """Delay track from the frames where the far end plays, or None without a reliable peak."""
    nfft = 2 * TRACK_FRAME
    freqs = np.fft.rfftfreq(nfft, 1 / SR)
    band = (freqs >= 200) & (freqs <= 4000)
    win = np.hanning(TRACK_FRAME)
    points = []
    for n in range(0, min(m.n, r.n) - TRACK_FRAME + 1, TRACK_HOP):
        x = r.read(n, TRACK_FRAME)
        if math.sqrt(float(x @ x) / TRACK_FRAME) < thr:
            continue
        lag, score = _gcc(m.read(n, TRACK_FRAME), x, win, band)
        if score >= TRACK_SCORE:
            points.append((n + TRACK_FRAME // 2, lag))
    runs = _pieces(points) if points else []
    if not runs:
        return None
    starts, delays = [], []
    for i, run in enumerate(runs):
        delays.append(int(np.median([q[1] for q in run])))
        # the step happened somewhere between the last frame of the previous piece and the first of this one
        starts.append(0 if i == 0 else (runs[i - 1][-1][0] + run[0][0]) // 2)
    return DelayTrack(np.array(starts), np.array(delays))


# ---------------------------------------------------------------- filter


class _Mdf:
    """Two-filter MDF echo canceller with leakage-controlled NLMS and a residual echo suppressor."""

    def __init__(self, thr: float):
        self.Wb = np.zeros((P, K), np.complex128)
        self.Wf = np.zeros((P, K), np.complex128)
        self.X = np.zeros((P, K), np.complex128)
        self.power = np.zeros(K)
        self.delta = NFFT * thr * thr          # regularization: the power of a barely active far end
        self.act = B * thr * thr                # far block energy that counts as activity
        self.Ebar = np.zeros(K)
        self.Ybar = np.zeros(K)
        self.Pey = 1e-12
        self.Pyy = 1e-12
        self.leak = 0.5
        self.adapted = False
        self.sum_adapt = 0.0
        self.Davg1 = self.Davg2 = self.Dvar1 = self.Dvar2 = 0.0
        self.zeros = np.zeros(B)
        self.fade = np.linspace(1.0, 0.0, B)
        # residual echo suppressor (sqrt-Hann STFT, 512/256)
        self.win = np.sqrt(np.hanning(NFFT + 1)[:NFFT])
        self.prev_e = np.zeros(B)
        self.prev_y = np.zeros(B)
        self.tail = np.zeros(B)
        self.Ss = np.zeros(K)
        self.Rs = np.zeros(K)
        self.res_e = np.full(K, 1e-9)    # residual and echo-estimate power while only the far end plays
        self.res_y = np.full(K, 1e-9)
        self.rho = np.full(K, 0.2)       # residual/echo ratio per bin
        self.far_only = False

    def reset_history(self):
        self.X[:] = 0
        self.prev_e[:] = 0
        self.prev_y[:] = 0
        self.tail[:] = 0

    def step(self, d: np.ndarray, xwin: np.ndarray):
        """One block: d = B mic samples, xwin = the last 2B aligned reference samples. -> (e, y) foreground."""
        Xn = np.fft.rfft(xwin)
        self.X[1:] = self.X[:-1]
        self.X[0] = Xn
        yb = np.fft.irfft((self.Wb * self.X).sum(axis=0))[B:]
        yf = np.fft.irfft((self.Wf * self.X).sum(axis=0))[B:]
        eb = d - yb
        ef = d - yf
        See = float(eb @ eb) + 1e-10
        Sff = float(ef @ ef) + 1e-10
        dy = yf - yb
        Dbf = float(dy @ dy) + 1e-10
        Sxx = float(xwin[B:] @ xwin[B:])

        # foreground / background (Speex logic)
        diff = Sff - See
        self.Davg1 = 0.6 * self.Davg1 + 0.4 * diff
        self.Davg2 = 0.85 * self.Davg2 + 0.15 * diff
        self.Dvar1 = 0.36 * self.Dvar1 + 0.16 * Sff * Dbf
        self.Dvar2 = 0.7225 * self.Dvar2 + 0.0225 * Sff * Dbf
        if (diff * abs(diff) > Sff * Dbf or self.Davg1 * abs(self.Davg1) > 2 * self.Dvar1
                or self.Davg2 * abs(self.Davg2) > 4 * self.Dvar2):
            self.Davg1 = self.Davg2 = self.Dvar1 = self.Dvar2 = 0.0
            self.Wf[:] = self.Wb
            ef = self.fade * ef + (1 - self.fade) * eb   # smooth switch inside the block
            yf = d - ef
        elif (-diff * abs(diff) > 4 * Sff * Dbf or -self.Davg1 * abs(self.Davg1) > 4 * self.Dvar1
              or -self.Davg2 * abs(self.Davg2) > 4 * self.Dvar2):
            self.Davg1 = self.Davg2 = self.Dvar1 = self.Dvar2 = 0.0
            self.Wb[:] = self.Wf
            eb, yb, See = ef, yf, Sff

        if Sxx > self.act:
            self._adapt(eb, yb, See, Sxx, Xn)

        if not np.isfinite(Sff) or Sff > 1e4 * (float(d @ d) + B * 1e-6):
            self.Wb[:] = 0
            self.Wf[:] = 0
            ef, yf = d.copy(), np.zeros(B)
        Syy = float(yf @ yf)
        self.far_only = Sxx > self.act and Syy > 1e-9 * B and float(d @ d) <= RES_FAR_ONLY * Syy
        return ef, yf

    def _adapt(self, eb, yb, See, Sxx, Xn):
        E = np.fft.rfft(np.concatenate([self.zeros, eb]))
        Y = np.fft.rfft(np.concatenate([self.zeros, yb]))
        Rf = E.real ** 2 + E.imag ** 2
        Yf = Y.real ** 2 + Y.imag ** 2
        Syy = float(yb @ yb) + 1e-10
        Sey = float(eb @ yb)
        ss = 0.35 / P
        self.power = (1 - ss) * self.power + ss * (Xn.real ** 2 + Xn.imag ** 2)

        # echo leakage (share of the echo estimate that is still in the error)
        Eh = Rf - self.Ebar
        Yh = Yf - self.Ybar
        self.Ebar = 0.95 * self.Ebar + 0.05 * Rf
        self.Ybar = 0.95 * self.Ybar + 0.05 * Yf
        beta0, beta_max = 2.0 * B / SR, 0.5 * B / SR
        beta = min(beta0 * Syy / See, beta_max)
        self.Pey = (1 - beta) * self.Pey + beta * float(Eh @ Yh)
        self.Pyy = (1 - beta) * self.Pyy + beta * float(Yh @ Yh)
        self.Pyy = max(self.Pyy, 1e-12)
        self.Pey = min(max(self.Pey, 0.005 * self.Pyy), self.Pyy)
        self.leak = self.Pey / self.Pyy
        if self.leak > 0.5:
            self.leak = 1.0

        norm = self.power + self.delta
        if self.adapted:
            rer = (1e-4 * Sxx + 3.0 * self.leak * Syy) / See
            rer = min(max(rer, Sey * Sey / (1 + See * Syy)), 0.5)
            r = self.leak * Yf
            e = Rf + 1e-10
            r = np.minimum(r, 0.5 * e)
            r = 0.7 * r + 0.3 * rer * e
            mu = r / (e * norm)
        else:
            rate = min(0.25 * Sxx, 0.25 * See) / See
            mu = rate / norm
            self.sum_adapt += rate
            if self.sum_adapt > P and self.leak > 0.03:
                self.adapted = True
        G = np.conj(self.X) * (mu * E / P)
        g = np.fft.irfft(G, axis=1)
        g[:, B:] = 0
        self.Wb += np.fft.rfft(g, axis=1)

    def suppress(self, e: np.ndarray, y: np.ndarray) -> np.ndarray:
        """Residual echo suppression; returns B output samples delayed by one block."""
        Ew = np.fft.rfft(self.win * np.concatenate([self.prev_e, e]))
        Yw = np.fft.rfft(self.win * np.concatenate([self.prev_y, y]))
        self.prev_e, self.prev_y = e, y
        S = Ew.real ** 2 + Ew.imag ** 2
        Yp = Yw.real ** 2 + Yw.imag ** 2
        if self.far_only:
            self.res_e = RES_RATE * self.res_e + (1 - RES_RATE) * S
            self.res_y = RES_RATE * self.res_y + (1 - RES_RATE) * Yp
            self.rho = np.clip(self.res_e / (self.res_y + 1e-12), RES_MIN, 1.0)
        self.Ss = 0.5 * self.Ss + 0.5 * S
        self.Rs = np.maximum(0.6 * self.Rs, self.rho * Yp)   # the echo tail decays slower than the estimate
        g = 1.0 - RES_ALPHA * self.Rs / (self.Ss + 1e-12)
        g = np.clip(np.convolve(g, [0.25, 0.5, 0.25], "same"), FLOOR, 1.0)    # less musical noise
        out = self.win * np.fft.irfft(Ew * g)
        res = self.tail + out[:B]
        self.tail = out[B:].copy()
        return res


# ---------------------------------------------------------------- driver


def _pass(c: _Mdf, m: _Reader, r: _Reader, track: DelayTrack, k0: int, k1: int, sink=None, stats=None):
    """Run blocks k0..k1-1 through the canceller. sink gets the output samples; stats (k1-k0, 5) the block energies."""
    first = True
    prev = None
    for k in range(k0, k1):
        n = k * B
        dl = track.at(n) - MARGIN
        if prev is not None and dl != prev:         # a step in the delay: the far-end history moves with it
            for j in range(P):
                c.X[j] = np.fft.rfft(r.read(n - (j + 2) * B - dl, NFFT))
        prev = dl
        d = m.read(n, B)
        x = r.read(n - B - dl, NFFT)
        e, y = c.step(d, x)
        out = c.suppress(e, y)
        if sink is not None:
            if not first:
                sink(out)
            first = False
        if stats is not None:
            xs = x[B:]
            stats[k - k0] = (d @ d, e @ e, y @ y, xs @ xs, out @ out)
    if sink is not None:
        sink(c.suppress(np.zeros(B), np.zeros(B)))


def _db(x: float) -> float:
    return 10 * math.log10(max(x, 1e-12))


def _evaluate(st: np.ndarray, thr: float) -> dict:
    """Region levels and echo reduction from per-block energies (d, e, y, x, out; out lags by one block)."""
    n = len(st) // 8 * 8
    if n == 0:
        return {}
    d, _, y, x = (st[:n, i] for i in range(4))
    out = np.concatenate([st[1:, 4], [0.0]])[:n]       # align the delayed suppressor output
    fr = lambda v: v.reshape(-1, 8).sum(axis=1)        # noqa: E731  128 ms frames
    d, y, x, out = fr(d), fr(y), fr(x), fr(out)
    act = 8 * B * thr * thr
    far = x > act
    recent = np.convolve(far.astype(float), np.ones(3))[:len(far)] > 0   # far end active within ~250 ms
    far_only = far & (y > 1e-9 * 8 * B) & (d <= 1.12 * y)
    near_only = ~recent & (d > 8 * B * 1e-4)
    res = {"far_s": float(far.sum() * 8 * B / SR), "far_only_s": float(far_only.sum() * 8 * B / SR),
           "near_only_s": float(near_only.sum() * 8 * B / SR)}
    if far.any():
        res["gain_db"] = _db(out[far].sum()) - _db(d[far].sum())
    if far_only.sum() >= 4:
        res["erle_db"] = _db(d[far_only].sum()) - _db(out[far_only].sum())
    span = 8 * B
    for name, mask in (("far_only", far_only), ("near_only", near_only)):
        if mask.any():
            res[f"{name}_in_db"] = _db(d[mask].sum() / (mask.sum() * span))
            res[f"{name}_out_db"] = _db(out[mask].sum() / (mask.sum() * span))
    return res


def cancel(mic: Path, ref: Path, delay: float | None = None, warmup: float = 60.0) -> Report:
    """Remove the reference's echo from mic (wav, rewritten in place when it helps). delay: seconds, skips the estimate."""
    t0 = time.monotonic()
    mic, ref = Path(mic), Path(ref)
    tmp = mic.with_name(mic.stem + ".aec.wav")
    try:
        report, track, thr, stats = _cancel(mic, ref, tmp, delay, warmup, t0)
        if report.applied:
            report.neural_reason = _run_neural(mic, ref, tmp, track, thr)
            report.neural = report.neural_reason == "ok"
            if report.neural:
                try:
                    _report_delivered(report, tmp, stats, thr)
                except Exception:  # noqa: BLE001  only the numbers are lost, the cleaned file is kept
                    pass
            os.replace(tmp, mic)
    finally:
        tmp.unlink(missing_ok=True)  # not applied, or an error part way: never left in the call folder
    report.seconds = time.monotonic() - t0
    return report


def _run_neural(mic: Path, ref: Path, tmp: Path, track: DelayTrack, thr: float) -> str:
    """The neural stage on the classic output in tmp. -> its result; never raises."""
    try:
        from . import aec_neural   # torch is imported only when there is echo to remove
        return aec_neural.apply(mic, ref, tmp, track, thr)
    except Exception as ex:  # noqa: BLE001  the classic output stays
        return f"error: {ex!r}"[:300]


def _report_delivered(report: Report, final: Path, stats: np.ndarray, thr: float) -> None:
    """Measure the delivered file against the same far-end regions the classic stage was judged on (the suppressor
    output in stats lags by one block, the file does not)."""
    energy = stats.copy()
    with wave.open(str(final), "rb") as w:
        blocks = min(len(energy) - 1, w.getnframes() // B)
        if blocks <= 0:
            return
        per = max(1, CHUNK // B)
        for i in range(0, blocks, per):
            n = min(per, blocks - i)
            data = np.frombuffer(w.readframes(n * B), "<i2").astype(np.float64) / 32768.0
            frames = data.reshape(n, B)
            energy[i + 1:i + n + 1, 4] = (frames * frames).sum(axis=1)
    energy[blocks + 1:, 4] = 0
    ev = _evaluate(energy.astype(np.float64), thr)
    report.gain_db = ev.get("gain_db", report.gain_db)
    report.erle_db = ev.get("erle_db", report.erle_db)
    report.levels = {**report.levels, **ev}


def _cancel(mic: Path, ref: Path, tmp: Path, delay: float | None, warmup: float, t0: float):
    """cancel() without the file handling: writes the cancelled mic to tmp.
    -> (report, delay track, far threshold, per-block energies)."""
    m, r = _Reader(mic), _Reader(ref)
    try:
        rms = _frame_rms(r)
        if not len(rms) or rms.max() < 1e-3:
            return Report(False, "no_far", seconds=time.monotonic() - t0), None, 0.0, None
        thr = max(1e-3, 0.03 * float(np.percentile(rms, 95)))
        if delay is None:
            track = estimate_delay(m, r, thr)
            if track is None:
                return Report(False, "no_delay", seconds=time.monotonic() - t0), None, 0.0, None
        else:
            track = DelayTrack(np.array([0]), np.array([int(round(delay * SR))]))
        report = Report(False, "", delay_ms=float(np.median(track.delays)) / SR * 1000,
                        drift_ms=float(track.delays[-1] - track.delays[0]) / SR * 1000,
                        jumps=len(track.delays) - 1)

        c = _Mdf(thr)
        nblocks = math.ceil(m.n / B)
        # warm-up: converge once on the minute with the most far-end activity, then process from the start
        per = max(1, int(warmup * SR) // GCC_FRAME)
        busy = np.convolve((rms > thr).astype(float), np.ones(per))[per - 1:] if len(rms) >= per else [0]
        w0 = int(np.argmax(busy)) * GCC_FRAME // B
        _pass(c, m, r, track, w0, min(nblocks, w0 + int(warmup * SR) // B))
        c.reset_history()

        stats = np.zeros((nblocks, 5), np.float32)   # 20 bytes per 16 ms: 9 MB for a 2 hour call
        w = _Writer(tmp)
        written = [0]

        def sink(x):
            take = min(len(x), m.n - written[0])
            if take > 0:
                w.write(x[:take])
                written[0] += take
        try:
            _pass(c, m, r, track, 0, nblocks, sink, stats)
        finally:
            w.close()
        ev = _evaluate(stats.astype(np.float64), thr)
        report.gain_db = ev.get("gain_db")
        report.erle_db = ev.get("erle_db")
        report.levels = ev
        if report.gain_db is not None and report.gain_db > 1.0:
            report.reason = "diverged"
        elif report.erle_db is None or report.erle_db < 3.0:
            report.reason = "no_echo"
        else:
            report.reason = "ok"
            report.applied = True
    finally:
        m.close()
        r.close()
    return report, track, thr, stats
