"""bin/trim_call.py: cut a call at its start and end (docs/CONTRACT.md, sections 3 to 5).

Times are seconds on the call's timeline (the same t0 as tracks.delays and the marks). Each track is cut at its own
offset, so the offsets between the tracks stay as they were. The cut tracks are written to .work and renamed into
place only once all of them are made: a failure before that leaves the folder as it was. Then the derived files go
(listen.m4a, mic.clean.m4a: the rerun makes new ones) and call.json gets the new audio times, the shifted marks and
`trimmed`. The whole operation holds the call folder's lock, so it never races a transcription.
"""
import argparse
import math
import os
import shutil
import time
from pathlib import Path

from . import audio, calls, jsonfile, platform_support
from .i18n import t
from .pipeline import guard, tracks
from .pipeline.run import EngineError, Exit, finish, log

KEYS = tuple(k for k, _ in tracks.TRACKS)
MIN_LENGTH = 10.0     # seconds that must remain (the app's handles keep at least this much)
MIN_GAP = 5.0         # marks closer than this are one mark (the app's CallMarks.minGap)
SLACK = 0.05          # a handle this far past the call's edge is the edge
DERIVED = ("listen.m4a", "mic.clean.m4a")


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else None


def _timeline(meta: dict) -> tuple[float, dict]:
    """-> (t0 on the recording clock, {track: (offset, seconds)}) for the tracks with a length."""
    starts = {k: _num(meta.get(f"{k}_start")) for k in KEYS}
    t0 = min((s for s in starts.values() if s is not None), default=0.0)
    out = {}
    for k in KEYS:
        sec = _num(meta.get(f"{k}_seconds"))
        if sec is not None and sec > 0:
            out[k] = ((starts[k] if starts[k] is not None else t0) - t0, sec)
    return t0, out


def call_end(meta: dict) -> float:
    """Length of the call timeline: the latest end over the tracks, offsets included."""
    return max((off + sec for off, sec in _timeline(meta)[1].values()), default=0.0)


def plan(meta: dict, start: float, end: float) -> dict:
    """What to keep of each track: {track: {"from": s, "to": s, "new_start": clock}}, "from" and "to" in the track's
    own seconds. A track with nothing in the range is left out (it is deleted). "new_start" keeps the track's offset
    from the new t0 (the old t0 + start) at max(0, old offset - start)."""
    t0, tl = _timeline(meta)
    out = {}
    for k, (off, sec) in tl.items():
        lo, hi = max(start, off), min(end, off + sec)
        if hi - lo <= 0:
            continue
        out[k] = {"from": round(lo - off, 6), "to": round(hi - off, 6),
                  "new_start": round(t0 + start + max(0.0, off - start), 6)}
    return out


def shift_marks(marks: list, start: float, end: float) -> list:
    """Marks inside [start, end] moved to the new timeline, rounded to 0.1 s, at least MIN_GAP apart."""
    out = []
    for m in sorted(x for x in (_num(v) for v in marks or []) if x is not None and start <= x <= end):
        s = round(m - start, 1)
        if out and s - out[-1] < MIN_GAP:
            continue
        out.append(s)
    return out


def _read(d: Path) -> dict:
    try:
        return calls.read_call(d, strict=True)
    except jsonfile.JsonFileError as e:
        raise EngineError(Exit.BAD_INPUT, t("err_bad_call", err=e)) from e


def _check(meta: dict, start: float, end: float) -> tuple[float, float]:
    """The range, clamped to the call's edges; EngineError(2) when it is not a range of this call."""
    if not _timeline(meta)[1]:
        raise EngineError(Exit.BAD_INPUT, t("err_no_audio"))
    length = call_end(meta)
    if not (math.isfinite(start) and math.isfinite(end)) or start < -SLACK or end > length + SLACK or start >= end:
        raise EngineError(Exit.BAD_INPUT, t("err_trim_range", start=start, end=end, length=length))
    if end - start < MIN_LENGTH:
        raise EngineError(Exit.BAD_INPUT, t("err_trim_short", n=int(MIN_LENGTH)))
    return max(0.0, start), min(length, end)


def local_end(d: Path, call: dict) -> float:
    """Length of the call's timeline from the tracks in the folder (call.json seconds, else the files' durations);
    0 without tracks. audio.FfmpegError when a track's length cannot be read."""
    files = tracks.track_files(d)
    meta = dict(calls.audio_meta(d, call))
    for k in KEYS:
        if k not in files:
            meta.pop(f"{k}_seconds", None)
        elif _num(meta.get(f"{k}_seconds")) is None:
            meta[f"{k}_seconds"] = audio.duration(files[k])
    return call_end(meta)


def trim_call(d: Path, start: float, end: float, now: str, locked: bool = False) -> None:
    """Cut the call folder `d` to [start, end] of its timeline. Raises EngineError (2: invalid input) or
    audio.FfmpegError; either way before anything in the folder changed. locked: the caller already holds the call
    folder's lock (sync replacing a copy trimmed on another Mac)."""
    d = Path(d)
    if not d.is_dir():
        raise EngineError(Exit.BAD_INPUT, t("err_no_dir", path=d))
    lock = None if locked else guard.lock_call(d, on_wait=lambda: log(t("log_waiting_for_run")))
    work = d / tracks.WORK
    try:
        call = _read(d)
        files = tracks.track_files(d)
        meta = dict(calls.audio_meta(d, call))
        for k in KEYS:
            if k not in files:
                meta.pop(f"{k}_seconds", None)   # no audio to cut; its start still sets t0, as in tracks.delays
            elif _num(meta.get(f"{k}_seconds")) is None:
                meta[f"{k}_seconds"] = audio.duration(files[k])
        old_end = call_end(meta)
        start, end = _check(meta, start, end)
        keep = plan(meta, start, end)
        if not keep:
            raise EngineError(Exit.BAD_INPUT, t("err_trim_no_audio"))
        # Where the kept audio really begins and ends on the old timeline (the range itself, unless no track reaches
        # one of its edges): the new t0 and the new end, for the marks and `trimmed`.
        tl = _timeline(meta)[1]
        head = min(tl[k][0] + p["from"] for k, p in keep.items())
        tail_at = max(tl[k][0] + p["to"] for k, p in keep.items())

        shutil.rmtree(work, ignore_errors=True)   # left by a run that was killed outright
        work.mkdir()
        cut = {}
        for k, p in keep.items():
            if p["from"] < 0.001 and p["to"] > tl[k][1] - 0.001:
                continue   # the whole track stays: no second encoding
            cut[k] = audio.cut(files[k], work / files[k].name, p["from"], p["to"] - p["from"])

        # Everything is made: from here on the folder changes, and the change is never left halfway by the app
        # quitting (cut tracks under the old call.json would be cut again by the next trim).
        with guard.committing():
            _commit(d, old_end=old_end, cut=cut, files=files, keep=keep, head=head, tail_at=tail_at, now=now)
        log(f"trimmed {head:.1f} s at the start and {old_end - tail_at:.1f} s at the end")
    finally:
        shutil.rmtree(work, ignore_errors=True)
        if lock is not None:
            os.close(lock)


def _commit(d: Path, old_end: float, cut: dict, files: dict, keep: dict, head: float, tail_at: float,
            now: str) -> None:
    """The derived files go, the cut tracks replace the old ones, the tracks with nothing kept go, call.json follows."""
    for name in DERIVED:
        platform_support.remove_file(d / name)
    for k, f in cut.items():
        platform_support.replace_file(f, files[k])
    for k in KEYS:
        if k not in keep:
            platform_support.remove_file(d / dict(tracks.TRACKS)[k])
    with jsonfile.locked(calls.call_file(d)):
        c = _read(d)
        new_audio = dict(calls.audio_meta(d, c))
        for k in KEYS:
            new_audio.pop(f"{k}_start", None)
            new_audio.pop(f"{k}_seconds", None)
            if k in keep:
                new_audio[f"{k}_start"] = keep[k]["new_start"]
                new_audio[f"{k}_seconds"] = round(keep[k]["to"] - keep[k]["from"], 3)
        c["audio"] = new_audio
        if "marks" in c:
            marks = shift_marks(c["marks"] if isinstance(c["marks"], list) else [], head, tail_at)
            if marks:
                c["marks"] = marks
            else:
                c.pop("marks")
        before = c.get("trimmed") if isinstance(c.get("trimmed"), dict) else {}
        c["trimmed"] = {"at": now,
                        "head": round((_num(before.get("head")) or 0.0) + head, 1),
                        "tail": round((_num(before.get("tail")) or 0.0) + old_end - tail_at, 1)}
        c.pop("silence", None)
        calls.write_call(d, c)


def parse_args(argv=None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Sozvon: cut a call at its start and end")
    ap.add_argument("dir", help="call folder with call.json and its tracks")
    ap.add_argument("--start", type=float, required=True, help="seconds on the call timeline where the call now starts")
    ap.add_argument("--end", type=float, required=True, help="seconds on the call timeline where the call now ends")
    return ap.parse_args(argv)


def main(argv=None) -> int:
    if argv is None:  # a real launch: tests pass arguments and start no thread
        guard.watch_parent()
        guard.exit_on_sigterm()
    args = parse_args(argv)
    try:
        trim_call(Path(args.dir).expanduser(), args.start, args.end,
                  now=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        return finish(Exit.OK)
    except EngineError as e:
        return finish(e.code, e.message)
    except audio.FfmpegError as e:
        return finish(Exit.FFMPEG, t("err_ffmpeg", file=e.file.name, err=e.detail))
    except (ImportError, audio.FfmpegMissing) as e:
        return finish(Exit.ENGINE_BROKEN, t("err_engine", err=e))
    except Exception as e:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        return finish(Exit.OTHER, f"{type(e).__name__}: {e}")
