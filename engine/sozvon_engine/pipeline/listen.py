"""listen.m4a: the call as one gently levelled file for the player. Nothing else in the pipeline reads it.

The prepared tracks are levelled each on its own: the gain curve comes from the 16 kHz working wav (loudness of the
voice over about 400 ms, measured on speech only), the audio it is applied to stays full band. Loud parts come down
hard, quiet ones go up gently and by at most MAX_UP, pauses are never raised, the gain moves ahead of loud parts, a
limiter holds each track and the mix at CEILING (before encoding: AAC can go slightly over it). A very quiet track is first
raised by what its working wav got, so it can end up more than MAX_UP above the recording. Everything is streamed in chunks (a call can be hours): 16 kHz analysis in
CHUNK_FRAMES, 48 kHz audio in CHUNK_SAMPLES, with enough context on each side that a chunk boundary is not audible.
"""
import itertools
import os
import subprocess
import time
import wave
from pathlib import Path

import numpy as np

from .. import audio, platform_support
from ..i18n import t
from . import tracks as tracks_stage

OUT = "listen.m4a"
RATE = 48000
HOP = 160                # 16 kHz samples in a 10 ms analysis frame
RATE_HOP = RATE * HOP // audio.SR
TARGET = -20.0           # dBFS of the voice's loudness the levelling aims at
DOWN = 0.85              # share of the excess above the target taken away
UP = 0.35                # share of the shortfall below the target given back
MAX_UP = 6.0             # dB, the most a quiet stretch is raised
CEILING = -1.5           # dBFS, the limiter's ceiling for each track and for the mix
CHUNK_S = 30
CHUNK_FRAMES = CHUNK_S * 100
CHUNK_SAMPLES = CHUNK_FRAMES * RATE_HOP
CONTEXT_FRAMES = 3000    # analysis frames of context on each side: a whole pause of this length is bridged
LIMIT_CONTEXT = 1024     # samples of context for the limiter's windows
LIMIT_WINDOW = 481       # samples, 10 ms: how far the limiter looks around a peak
LIMIT_SIGMA = 144        # samples, 3 ms: smoothing of the limiter's gain (never wider than the window, or peaks get through)
FLOOR_BINS = np.arange(-120.0, 20.05, 0.1)
ENCODER = ("-c:a", "aac", "-b:a", "72k")  # mono: about 33 MB per hour


def _db(p):
    return 10 * np.log10(np.maximum(p, 1e-12))


def _windowed(chunks, context: int):
    """Chunks with `context` items of their neighbours on each side. -> (left, chunk, right)."""
    cur = next(chunks, None)
    if cur is None:
        return
    tail = empty = cur[:0]
    for nxt in chunks:
        yield tail, cur, nxt[:context]
        tail, cur = np.concatenate([tail, cur])[-context:], nxt
    yield tail, cur, empty


def _read_frames(wav):
    """10 ms power frames of a 16 kHz mono wav, CHUNK_FRAMES at a time. Reads a piece at a time."""
    with wave.open(str(wav), "rb") as w:
        while True:
            x = np.frombuffer(w.readframes(CHUNK_FRAMES * HOP), "<i2").astype(np.float64) / 32768
            n = len(x) // HOP
            if n == 0:
                return
            yield (x[:n * HOP].reshape(n, HOP) ** 2).mean(1)


def _gate(frames) -> float:
    """The level above which a frame counts as speech, from the whole track (15th percentile of what is above -90)."""
    hist = np.zeros(len(FLOOR_BINS) - 1, dtype=np.int64)
    for p in frames:
        hist += np.histogram(_db(p), FLOOR_BINS)[0]
    hist[FLOOR_BINS[:-1] < -90] = 0
    total = hist.sum()
    floor = FLOOR_BINS[np.searchsorted(hist.cumsum(), total * 0.15)] + 0.05 if total else -90.0
    return max(-50.0, floor + 12)


def _curve(p, gate: float, last: float):
    """The gain in dB of a stretch of frames, speech only. No speech in the stretch: the previous gain, never raised."""
    from scipy.ndimage import gaussian_filter1d, minimum_filter1d  # here, so a broken scipy costs only this file
    n = len(p)
    active = gaussian_filter1d((_db(p) > gate).astype(float), 8) > 0.3
    if not active.any():
        return np.full(n, min(last, 0.0))
    # loudness of the voice over about 400 ms, measured only on speech
    w = gaussian_filter1d(p * active, 15) / np.maximum(gaussian_filter1d(active.astype(float), 15), 1e-3)
    d = _db(w) - TARGET
    g = np.where(d > 0, -d * DOWN, np.minimum(-d * UP, MAX_UP))
    # pauses: keep the neighbouring gain but never raise, so hiss does not come up
    idx = np.arange(n)
    g = np.interp(idx, idx[active], g[active])
    g[~active] = np.minimum(g[~active], 0)
    # react to loud parts before they arrive, then smooth
    return gaussian_filter1d(minimum_filter1d(g, 11), 10)


def gain_db_stream(frames_fn):
    """The gain curve in dB, per 10 ms frame, chunk by chunk. frames_fn() starts a new pass over the frames. -> (first frame, g)."""
    gate = _gate(frames_fn())
    last = 0.0
    for i, (left, cur, right) in enumerate(_windowed(frames_fn(), CONTEXT_FRAMES)):
        g = _curve(np.concatenate([left, cur, right]), gate, last)[len(left):len(left) + len(cur)]
        last = float(g[-1])
        yield i * CHUNK_FRAMES, g


class _Decoder:
    """A track as 48 kHz mono samples from a pipe, read a piece at a time. `delay` is applied like audio.to_wav. Decoded to
    16-bit like the working wav: ffmpeg normalizes a stereo downmix only for integer output, float comes out 3 dB louder."""

    def __init__(self, path, delay: float):
        self.path = path
        try:
            args = [platform_support.tool_path("ffmpeg"), "-nostdin", "-v", "error", "-i", str(path),
                    *audio.delay_filter(delay), "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"]
            self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except FileNotFoundError as e:
            raise audio.FfmpegMissing("ffmpeg") from e

    def read(self, n: int):
        raw = self.proc.stdout.read(n * 2)
        x = np.frombuffer(raw[:len(raw) & ~1], "<i2").astype(np.float32) / 32768
        if len(x) == 0 and self.proc.wait() != 0:
            raise audio.FfmpegError(self.path, f"exit {self.proc.returncode}")
        return x

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.stdout.close()
        self.proc.wait()


def track_pcm(wav, source, delay: float = 0.0, boost: float = 1.0):
    """One track levelled, 48 kHz float chunks: gain from the 16 kHz `wav`, audio from `source` (`delay`: seconds, `boost`:
    the raise the working wav got, applied to the original audio so the gain curve fits it)."""
    decoder = _Decoder(source, delay)
    curves = gain_db_stream(lambda: _read_frames(wav))
    try:
        cur, nxt = next(curves, None), next(curves, None)
        first_sample = 0
        prev = None  # the last frame's gain of the previous chunk, for the interpolation across the boundary
        last_db = 0.0
        while (x := decoder.read(CHUNK_SAMPLES)).size:
            if cur is None:
                db = last_db
            else:
                first, g = cur
                idx, values = np.arange(first, first + len(g)), g
                if prev is not None:
                    idx, values = np.r_[first - 1, idx], np.r_[prev, values]
                if nxt is not None:
                    idx, values = np.r_[idx, first + len(g)], np.r_[values, nxt[1][0]]
                db = np.interp(first_sample + np.arange(len(x)), idx * RATE_HOP + RATE_HOP / 2, values)
                prev, last_db = g[-1], float(g[-1])
                cur, nxt = nxt, next(curves, None)
            yield np.float32(x * boost * 10 ** (db / 20))
            first_sample += len(x)
    finally:
        decoder.close()


def _limit(y):
    from scipy.ndimage import gaussian_filter1d, minimum_filter1d
    limit = np.float32(10 ** (CEILING / 20))
    need = np.minimum(1.0, limit / np.maximum(np.abs(y), 1e-9))
    need = minimum_filter1d(need, LIMIT_WINDOW)
    return y * gaussian_filter1d(need, LIMIT_SIGMA, truncate=(LIMIT_WINDOW // 2) / LIMIT_SIGMA)


def limited(chunks):
    """A stream of chunks through the limiter (no sample above CEILING), with context across chunk boundaries."""
    for left, cur, right in _windowed(iter(chunks), LIMIT_CONTEXT):
        y = _limit(np.concatenate([left, cur, right]))
        yield np.float32(y[len(left):len(left) + len(cur)])


def mix_chunks(streams):
    """The tracks added, the shorter ones padded with silence, the sum through the limiter."""
    def added():
        for chunks in itertools.zip_longest(*streams):
            present = [c for c in chunks if c is not None]
            mix = np.zeros(max(len(c) for c in present), dtype=np.float32)
            for c in present:
                mix[:len(c)] += c
            yield mix
    return limited(added())


def mix_pcm(files: dict, offsets: dict, tracks: dict, gains: dict):
    """The levelled call as 48 kHz float chunks, aligned to the call's start, as long as its longest track.
    The working wavs (`tracks`) give the gain. The audio is each track's own full band, delayed and raised as its working
    wav was, except a mic whose echo was removed on this run (`gains["mic_echo_free"]`): that exists only at 16 kHz, already
    aligned and raised, so the working wav is the audio. A track prepare() dropped for having no speech is still heard in
    the player today, so it is levelled from a fresh working wav."""
    streams = []
    for key, _ in tracks_stage.TRACKS:
        if key not in files:
            continue
        delay = offsets.get(key, 0.0)
        wav, boost = tracks.get(key), gains.get(key, 1.0)
        if wav is None:
            work = Path(files[key]).parent / tracks_stage.WORK
            wav, boost = audio.to_wav(files[key], work / f"{key}.listen.wav", delay), 1.0
        if key == "mic" and gains.get("mic_echo_free") and key in tracks:
            streams.append(limited(track_pcm(wav, wav)))
        else:
            streams.append(limited(track_pcm(wav, files[key], delay, boost)))
    yield from mix_chunks(streams)


def _stop(encoder) -> None:
    """The encoder is gone once this returns: killed if it is still running, and waited for."""
    if encoder is None:
        return
    if encoder.poll() is None:
        encoder.kill()
        encoder.wait()
    try:
        encoder.stdin.close()
    except BrokenPipeError:
        pass


def _write(d: Path, files: dict, offsets: dict, tracks: dict, gains: dict) -> bool:
    out = d / OUT
    tmp = d / tracks_stage.WORK / OUT
    pcm = encoder = None
    try:
        out.unlink(missing_ok=True)
        if not files:
            return False
        tmp.parent.mkdir(exist_ok=True)
        pcm = mix_pcm(files, offsets, tracks, gains)
        encoder = subprocess.Popen([platform_support.tool_path("ffmpeg"), "-nostdin", "-v", "error", "-y", "-f", "f32le",
                                    "-ar", str(RATE), "-ac", "1", "-i", "-", *ENCODER, str(tmp)],
                                   stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
        total = 0
        for chunk in pcm:
            encoder.stdin.write(chunk.tobytes())
            total += len(chunk)
        encoder.stdin.close()
        if encoder.wait() != 0 or not total:
            raise RuntimeError(f"ffmpeg exit {encoder.returncode}" if total else "no audio")
        platform_support.replace_file(tmp, out)
        return True
    finally:
        _stop(encoder)
        if pcm is not None:
            pcm.close()
        tmp.unlink(missing_ok=True)


def render(d: Path, files: dict, offsets: dict, tracks: dict, gains: dict, log) -> bool:
    """Writes listen.m4a in the call folder from the prepared tracks; the old one goes first. Never raises, cleanup included:
    a failure means no file and a log line (the player falls back to the tracks). An exit (SIGTERM) passes through, after the
    cleanup. -> whether the file was written."""
    t0 = time.monotonic()
    try:
        if not _write(Path(d), files, offsets, tracks, gains):
            return False
        log(t("log_listen_ok", sec=time.monotonic() - t0))
        return True
    except Exception as ex:  # noqa: BLE001  listening falls back to the tracks; the transcript is not affected
        log(t("log_listen_failed", err=ex))
        return False
