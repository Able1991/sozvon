"""Call tracks: wav, whether there is speech, where system audio dropped out, remote echo in the mic.

mic.m4a is always "me", system.m4a is always the other side: who is who is known without guessing.
The "speakers instead of headphones" pitfall: the mic hears the other person from the speakers, and
their phrase lands in the transcript twice. The echo is first cancelled in the mic signal itself
(aec.py, system.wav is the exact reference); mic phrases that still repeat the other side are dropped
(drop_echo).
"""
import difflib
import os
import re
import shutil
from pathlib import Path

import numpy as np

from .. import aec, audio, paths
from ..i18n import t
from ..paths import EngineDir

TRACKS = (("mic", "mic.m4a"), ("system", "system.m4a"))
MIN_FILE_BYTES = 1024
WORK = ".work"  # the call's working files (wavs, echo cancellation temp): hidden, the app clears it at launch


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


def drop_echo(mic: list, system: list, window: float = 3.0, thr: float = 0.6, min_words: int = 2) -> tuple[list, int]:
    """Drop remote phrases the mic picked up from the speakers. -> (kept, dropped).
    A one-word reply ("Да.") is always kept: its letters are found in almost any nearby remote phrase."""
    kept, dropped = [], 0
    for s, e, text in mic:
        near = " ".join(_norm(tt) for ss, ee, tt in system if ee >= s - window and ss <= e + window)
        a = _norm(text)
        if len(a.split()) >= min_words and near:
            sm = difflib.SequenceMatcher(None, a, near, autojunk=False)
            if sum(b.size for b in sm.get_matching_blocks()) / len(a) >= thr:
                dropped += 1
                continue
        kept.append((s, e, text))
    return kept, dropped


# A track whose loud parts stay below -20 dBFS is quiet (a low input volume, a far microphone): raised to about
# -6 dBFS before speech detection and recognition, at most by 30 dB so room noise does not become speech.
QUIET = 0.1
TARGET = 0.5
MAX_GAIN = 31.6


def loudness(x) -> float:
    """Level of the loud parts: the 99.5th percentile of |sample| (a single click does not count)."""
    return float(np.percentile(np.abs(x), 99.5)) if len(x) else 0.0


def boost(wav: Path) -> float:
    """Raise a quiet 16 kHz mono wav in place. -> the gain applied (1.0: left as is)."""
    import wave
    try:
        x = audio.decode(wav)
    except Exception:  # noqa: BLE001  an unreadable track is reported by the next step, never by this one
        return 1.0
    p = loudness(x)
    if p <= 1e-4 or p >= QUIET:
        return 1.0
    g = min(TARGET / p, MAX_GAIN)
    y = (np.clip(x * g, -1.0, 1.0) * 32767).astype("<i2")
    with wave.open(str(wav), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(audio.SR)
        w.writeframes(y.tobytes())
    return g


def prepare(files: dict, offsets: dict, d: Path, log, warn=None, gains: dict | None = None) -> dict:
    """Tracks -> wav in <call>/.work (a very quiet one raised, the speaker echo removed from the mic);
    tracks without speech are discarded. warn(step, error): a failure for call.json "warnings".
    gains, when given: {key: the raise applied} and "mic_echo_free": whether echo was removed from the mic on this run,
    for the listening file. -> {key: wav}."""
    work = Path(d) / WORK
    shutil.rmtree(work, ignore_errors=True)  # left by a run that was killed outright
    work.mkdir(exist_ok=True)
    out = {}
    improved = False
    for key, src in files.items():
        wav = audio.to_wav(src, work / f"{key}.wav", offsets.get(key, 0.0))
        g = boost(wav)
        if gains is not None:
            gains[key] = g
        if g > 1.01:
            log(t("log_track_boost", file=src.name, db=20 * np.log10(g)))
            improved = improved or key == "mic"
        act = active_seconds(wav)
        log(t("log_track_speech", file=src.name, sec=act))
        if act >= 1.0:
            out[key] = wav
        else:
            wav.unlink(missing_ok=True)
    if "mic" in out and "system" in out and os.environ.get("SOZVON_AEC", "1") != "0":
        echo_free = cancel_echo(out["mic"], out["system"], log, warn)
        improved = echo_free or improved
        if gains is not None:
            gains["mic_echo_free"] = echo_free
    save_clean_mic(Path(d), out.get("mic") if improved else None, log)
    return out


CLEAN_MIC = "mic.clean.m4a"


def save_clean_mic(d: Path, wav, log) -> None:
    """Keep the raised and echo-free microphone for listening (mic.clean.m4a, aligned to the call's start: it
    plays at offset 0). The original mic.m4a stays for transcribing again. No improvement: an old copy goes."""
    out = Path(d) / CLEAN_MIC
    if wav is None:
        out.unlink(missing_ok=True)
        return
    try:
        audio.to_m4a(Path(wav), out)
    except Exception as ex:  # noqa: BLE001  listening falls back to mic.m4a
        log(t("log_clean_mic_failed", err=ex))


def cancel_echo(mic: Path, system: Path, log, warn=None) -> bool:
    """Offline echo cancellation of mic.wav with system.wav as the reference (aec.py). Never fails the call.
    -> whether the echo was removed. warn(step, error): the neural stage failed, for call.json "warnings"."""
    try:
        r = aec.cancel(mic, system)
    except Exception as ex:  # noqa: BLE001  the mic stays as it was
        log(t("log_aec_failed", err=ex))
        return False
    if r.applied:
        log(t("log_aec_ok", db=r.erle_db, ms=r.delay_ms))
        if r.neural:
            log(t("log_aec_neural"))
        elif r.neural_reason:
            _report_neural_skip(r.neural_reason, log, warn)
    else:
        log(t("log_aec_skip", why=t(f"aec_{r.reason}")))
    return bool(r.applied)


def _report_neural_skip(reason: str, log, warn) -> None:
    """The classic output stays: one log line with the reason, and a call warning for what the user should know about.
    Weights that simply are not there yet warn once, for the download that failed (the marker from install.py)."""
    key, _, detail = reason.partition(": ")
    log(t("log_aec_neural_skip", why=t(f"aec_neural_{key}", err=detail)))
    if warn is None:
        return
    if key == "no_weights":
        marker = EngineDir(paths.data_dir()).no_echo_model
        if not marker.exists():
            return
        marker.unlink(missing_ok=True)
    elif key == "off":
        return
    warn("echo", reason)


def cleanup(d: Path) -> None:
    """Remove the work files of a transcription: the .work folder, and the wavs that versions before it
    left in the call folder itself."""
    shutil.rmtree(Path(d) / WORK, ignore_errors=True)
    for key, _ in TRACKS:
        (Path(d) / f"{key}.wav").unlink(missing_ok=True)
    for f in Path(d).glob("*.aec.wav"):
        f.unlink(missing_ok=True)
