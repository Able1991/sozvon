"""Offline acoustic echo cancellation of the microphone track.

Without headphones the microphone hears the speakers: the other side's voices come back in mic.wav,
delayed by the device and the air (tens to hundreds of milliseconds) and colored by the room. system.wav
is exactly what the speakers played, so it is a perfect far-end reference.

Steps, all streaming over 16 kHz mono 16-bit wav files (memory stays bounded for any call length):
1. Bulk delay: GCC-PHAT between the mic and the reference over the frames with the strongest far-end
   activity, per minute, so a slow clock drift between the two captures is followed linearly.
2. A partitioned-block frequency-domain adaptive filter (MDF, as in Speex): 256-sample blocks, 512-point
   FFTs (50% overlap-save), 16 partitions (256 ms of echo path after the bulk delay). NLMS with a
   per-bin learning rate from the estimated echo leakage (Valin 2007): when the near end talks the
   error is large next to the echo estimate and adaptation almost stops. Two filters: the background one
   adapts, the foreground one produces the output and only takes the background weights when they are
   clearly better; a background filter ruined by double talk is reset from the foreground.
3. A mild residual echo suppressor: a Wiener-like spectral gain from the leakage times the echo estimate,
   never below -20 dB.
4. Safety: if the output in far-end regions is louder than the input, or almost no echo was removed,
   the original microphone is kept.
"""
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
MAX_DELAY = 0.5            # delay search range, seconds: the echo comes after the reference...
MIN_DELAY = -0.05          # ...but the tracks' start offsets are only accurate to a few tens of ms
FLOOR = 0.1                # residual suppressor gain floor (-20 dB)
CHUNK = 30 * SR            # read and write in 30 s pieces

GCC_FRAME = 2 * SR         # 2 s frames for the delay estimate
GCC_WINDOW = 60.0          # one delay estimate per minute (the capture clocks drift by ~10 ppm)
GCC_FRAMES = 20            # strongest far-end frames used per window
GCC_SCORE = 9.0            # peak height over the robust noise level of the correlation


@dataclass
class Report:
    applied: bool
    reason: str                       # ok, no_far, no_delay, no_echo, diverged
    delay_ms: float | None = None     # bulk delay at the start of the call
    drift_ms: float = 0.0             # delay change from the start to the end of the call
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
            y = np.clip(np.concatenate(self.parts), -1.0, 1.0)
            self.w.writeframes((y * 32767).astype("<i2").tobytes())
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


def _gcc(m: _Reader, r: _Reader, frames) -> tuple[int, float]:
    """GCC-PHAT summed over frames. -> (lag in samples where the mic lags the reference, peak score)."""
    nfft = 2 * GCC_FRAME
    freqs = np.fft.rfftfreq(nfft, 1 / SR)
    band = (freqs >= 200) & (freqs <= 4000)
    acc = np.zeros(len(freqs), np.complex128)
    for i in frames:
        mf = np.fft.rfft(m.read(i * GCC_FRAME, GCC_FRAME), nfft)
        rf = np.fft.rfft(r.read(i * GCC_FRAME, GCC_FRAME), nfft)
        c = mf * np.conj(rf)
        acc += np.where(band, c / (np.abs(c) + 1e-20), 0)
    neg, maxlag = int(-MIN_DELAY * SR), int(MAX_DELAY * SR)
    full = np.fft.irfft(acc, nfft)
    cc = np.concatenate([full[-neg:], full[:maxlag + 1]])   # lags -neg..maxlag
    k = int(np.argmax(cc))
    rest = np.concatenate([cc[:max(0, k - 32)], cc[k + 33:]])
    med = float(np.median(rest))
    sigma = 1.4826 * float(np.median(np.abs(rest - med))) + 1e-12
    return k - neg, (float(cc[k]) - med) / sigma


def estimate_delay(m: _Reader, r: _Reader, rms: np.ndarray, thr: float):
    """Delay track as (start delay, slope) in samples and samples per sample, or None without a reliable peak."""
    per = max(1, int(GCC_WINDOW * SR) // GCC_FRAME)
    nwin = max(1, math.ceil(len(rms) / per))
    if nwin > 1 and len(rms) - (nwin - 1) * per < per // 2:
        nwin -= 1   # a short tail joins the previous window
    points = []
    for w in range(nwin):
        lo, hi = w * per, (len(rms) if w == nwin - 1 else (w + 1) * per)
        idx = np.arange(lo, hi)
        idx = idx[rms[lo:hi] > thr]
        if len(idx) < 3:
            continue
        idx = idx[np.argsort(rms[idx])[::-1][:GCC_FRAMES]]
        lag, score = _gcc(m, r, idx)
        if score >= GCC_SCORE:
            points.append(((float(np.mean(idx)) + 0.5) * GCC_FRAME, lag))
    if not points:
        return None
    t = np.array([p[0] for p in points])
    d = np.array([p[1] for p in points], float)
    med = float(np.median(d))
    if len(points) >= 3:
        # robust line: echo reflections sometimes win a window, drop points far from the fit and refit
        keep = np.ones(len(d), bool)
        for _ in range(3):
            slope, icpt = np.polyfit(t[keep], d[keep], 1)
            res = np.abs(d - (icpt + slope * t))
            keep = res <= max(24.0, 3 * 1.4826 * float(np.median(res[keep])))
            if keep.sum() < 3:
                break
        if keep.sum() >= 3:
            slope, icpt = np.polyfit(t[keep], d[keep], 1)
            if abs(slope * m.n) >= 16:   # drift of at least 1 ms over the call
                return float(icpt), float(slope)
            med = float(np.median(d[keep]))
    return med, 0.0


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
        leak2 = 1.0 if self.leak > 0.5 else 2 * self.leak
        S = Ew.real ** 2 + Ew.imag ** 2
        R = leak2 * (Yw.real ** 2 + Yw.imag ** 2)
        self.Ss = 0.5 * self.Ss + 0.5 * S
        self.Rs = np.maximum(0.6 * self.Rs, R)      # the echo tail decays slower than the estimate
        g = np.clip(1.0 - 1.5 * self.Rs / (self.Ss + 1e-12), FLOOR, 1.0)
        out = self.win * np.fft.irfft(Ew * g)
        res = self.tail + out[:B]
        self.tail = out[B:].copy()
        return res


# ---------------------------------------------------------------- driver


def _pass(c: _Mdf, m: _Reader, r: _Reader, dtrack, k0: int, k1: int, sink=None, stats=None):
    """Run blocks k0..k1-1 through the canceller. sink gets the output samples; stats (k1-k0, 5) the block energies."""
    a, b = dtrack
    first = True
    for k in range(k0, k1):
        n = k * B
        dl = int(round(a + b * n)) - MARGIN
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
        report = _cancel(mic, ref, tmp, delay, warmup, t0)
        if report.applied:
            os.replace(tmp, mic)
    finally:
        tmp.unlink(missing_ok=True)  # not applied, or an error part way: never left in the call folder
    report.seconds = time.monotonic() - t0
    return report


def _cancel(mic: Path, ref: Path, tmp: Path, delay: float | None, warmup: float, t0: float) -> Report:
    """cancel() without the file handling: writes the cancelled mic to tmp and says whether to keep it."""
    m, r = _Reader(mic), _Reader(ref)
    try:
        rms = _frame_rms(r)
        if not len(rms) or rms.max() < 1e-3:
            return Report(False, "no_far", seconds=time.monotonic() - t0)
        thr = max(1e-3, 0.03 * float(np.percentile(rms, 95)))
        if delay is None:
            dtrack = estimate_delay(m, r, rms, thr)
            if dtrack is None:
                return Report(False, "no_delay", seconds=time.monotonic() - t0)
        else:
            dtrack = (delay * SR, 0.0)
        a, b = dtrack
        report = Report(False, "", delay_ms=a / SR * 1000, drift_ms=b * m.n / SR * 1000)

        c = _Mdf(thr)
        nblocks = math.ceil(m.n / B)
        # warm-up: converge once on the minute with the most far-end activity, then process from the start
        per = max(1, int(warmup * SR) // GCC_FRAME)
        busy = np.convolve((rms > thr).astype(float), np.ones(per))[per - 1:] if len(rms) >= per else [0]
        w0 = int(np.argmax(busy)) * GCC_FRAME // B
        _pass(c, m, r, dtrack, w0, min(nblocks, w0 + int(warmup * SR) // B))
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
            _pass(c, m, r, dtrack, 0, nblocks, sink, stats)
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
    return report
