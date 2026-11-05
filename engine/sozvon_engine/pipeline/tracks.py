"""Call tracks: wav, whether there is speech, where system audio dropped out, remote echo in the mic.

mic.m4a is always "me", system.m4a is always the other side: who is who is known without guessing.
The "speakers instead of headphones" pitfall: the mic hears the other person from the speakers, and
their phrase lands in the transcript twice. Such mic segments are dropped (drop_echo).
"""
import difflib
import re
from pathlib import Path

import numpy as np

from .. import audio
from ..i18n import t

TRACKS = (("mic", "mic.m4a"), ("system", "system.m4a"))
MIN_FILE_BYTES = 1024


def track_files(d: Path) -> dict:
    """{key: file} for the tracks that were recorded at all."""
    out = {}
    for key, name in TRACKS:
        f = Path(d) / name
        if f.exists() and f.stat().st_size >= MIN_FILE_BYTES:
            out[key] = f
    return out


def delays(meta: dict) -> dict:
    """Start offset of each track relative to the earliest one (by the shared recording clock)."""
    starts = {k: float(meta[f"{k}_start"]) for k, _ in TRACKS
              if isinstance(meta.get(f"{k}_start"), (int, float))}
    t0 = min(starts.values(), default=0.0)
    return {k: starts.get(k, t0) - t0 for k, _ in TRACKS}


def active_seconds(wav: Path) -> float:
    """How many seconds of the track actually contain sound (rough energy VAD, 30 ms frames)."""
    x = audio.decode(wav)
    frame = 480
    n = len(x) // frame
    if n == 0:
        return 0.0
    rms = np.sqrt((x[: n * frame].reshape(n, frame) ** 2).mean(axis=1))
    return float((rms > 0.01).sum() * 0.03)


def dead_spans(wav: Path, min_len: float = 60.0) -> list:
    """Spans of digital silence (audio capture dropped out) longer than min_len. -> [(start, end)]."""
    x = audio.decode(wav)
    frame = 1600  # 0.1 s
    n = len(x) // frame
    if n == 0:
        return []
    dead = np.abs(x[: n * frame].reshape(n, frame)).max(axis=1) < 1e-4
    spans, start = [], None
    for i, flag in enumerate(list(dead) + [False]):
        if flag and start is None:
            start = i
        elif not flag and start is not None:
            if (i - start) * 0.1 >= min_len:
                spans.append((start * 0.1, i * 0.1))
            start = None
    return spans


def split_dead(mic: list, spans: list) -> tuple[list, list]:
    """Split mic utterances into those outside and inside system audio gaps."""
    def inside(s, e):
        return any(ds - 1 <= s and e <= de + 1 for ds, de in spans)
    return [x for x in mic if not inside(x[0], x[1])], [x for x in mic if inside(x[0], x[1])]


def _norm(text: str) -> str:
    return re.sub(r"[^\w]+", " ", text.lower()).strip()


def drop_echo(mic: list, system: list, window: float = 3.0, thr: float = 0.6) -> tuple[list, int]:
    """Drop remote phrases the mic picked up from the speakers. -> (kept, dropped)."""
    kept, dropped = [], 0
    for s, e, text in mic:
        near = " ".join(_norm(tt) for ss, ee, tt in system if ee >= s - window and ss <= e + window)
        a = _norm(text)
        if a and near:
            sm = difflib.SequenceMatcher(None, a, near, autojunk=False)
            if sum(b.size for b in sm.get_matching_blocks()) / len(a) >= thr:
                dropped += 1
                continue
        kept.append((s, e, text))
    return kept, dropped


def prepare(files: dict, offsets: dict, d: Path, log) -> dict:
    """Tracks -> wav in the call folder; tracks without speech are discarded. -> {key: wav}."""
    out = {}
    for key, src in files.items():
        wav = audio.to_wav(src, Path(d) / f"{key}.wav", offsets.get(key, 0.0))
        act = active_seconds(wav)
        log(t("log_track_speech", file=src.name, sec=act))
        if act >= 1.0:
            out[key] = wav
        else:
            wav.unlink(missing_ok=True)
    return out


def cleanup(d: Path) -> None:
    for key, _ in TRACKS:
        (Path(d) / f"{key}.wav").unlink(missing_ok=True)
