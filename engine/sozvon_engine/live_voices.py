"""Live voice hints during a recording (docs/CONTRACT.md, "Live voices").

While a call is recorded, the app drops a piece of the other side's track into <call>/.live/ every minute
(system-0001.wav, ...). This process, started by the app with the recording, embeds the speech in each piece
window by window with the same model as the voice prints and matches every window against the saved voices
(any project, never the user's own). The tally goes to <call>/.live/voices.json after every piece, so when the
recording stops the app knows who was most likely on the call and fills "What was the call about?" with them,
before the transcription.

It is a hint, not the transcript: windows are matched one by one without speaker separation, with a stricter
threshold than the pipeline, and a name counts only after MIN_SECONDS of matched speech. The transcription
still names the voices on its own afterwards.

Every piece is deleted as soon as it is matched. Ends when <call>/.live/stop exists and every piece is done, or
when the app or the folder is gone.
"""
import json
import time
from pathlib import Path

from . import audio, jsonfile, platform_support, voices

CHUNKS = "system-*.wav"
RESULT = "voices.json"
STOP = "stop"
THRESHOLD = 0.6          # stricter than voices.THRESHOLD: one window, no clustering
MIN_WINDOW = 1.5         # seconds of speech in one window
WINDOW = 6.0             # seconds per window
MIN_SECONDS = 6.0        # matched speech for a name to count as a participant
TWIN = 0.75              # two names with prints this close are one voice (different people are ~0.1-0.45)


def records(log=None) -> list:
    """Voices the call can be matched against: every saved voice of the current model except the user's own."""
    return [r for r in voices.only_current(voices.load_all(), log) if not r["me"]]


def twins(recs: list) -> dict:
    """{name: names whose prints are nearly the same as this name's}: one voice saved under two names."""
    out: dict = {}
    for a in recs:
        for b in recs:
            if a["name"] != b["name"] and float(voices.unit(a["embedding"]) @ voices.unit(b["embedding"])) >= TWIN:
                out.setdefault(a["name"], set()).add(b["name"])
    return out


def match(vec, recs: list, twin: dict):
    """One window -> (record, score, unsure) or None. Like voices.match, but the margin is measured against other
    voices: two names of one voice can't be told apart, so the name with more enrolled speech stands in, unsure."""
    v = voices.unit(vec)
    best: dict = {}
    for r in recs:
        score = float(v @ voices.unit(r["embedding"]))
        if r["name"] not in best or score > best[r["name"]][0]:
            best[r["name"]] = (score, r)
    if not best:
        return None
    top_name = max(best, key=lambda n: best[n][0])
    top = best[top_name][0]
    same = twin.get(top_name, set())
    others = [s for n, (s, _) in best.items() if n != top_name and n not in same]
    if top < THRESHOLD or (others and top - max(others) < voices.MARGIN):
        return None
    group = [top_name] + [n for n in same if n in best and top - best[n][0] < voices.MARGIN]
    chosen = max(group, key=lambda n: best[n][1].get("seconds", 0.0))
    return best[chosen][1], top, len(group) > 1


def windows(pieces: list, sr: int = audio.SR) -> list:
    """Speech pieces cut into windows of WINDOW seconds; windows shorter than MIN_WINDOW are dropped."""
    out, step = [], int(WINDOW * sr)
    for p in pieces:
        for i in range(0, len(p), step):
            w = p[i:i + step]
            if len(w) >= MIN_WINDOW * sr:
                out.append(w)
    return out


class Tally:
    """Matched seconds per name, with the name's project (from its voice print)."""

    def __init__(self):
        self.names: dict = {}
        self.pieces = 0
        self.speech = 0.0

    def add(self, rec: dict, seconds: float, score: float, unsure: bool = False) -> None:
        t = self.names.setdefault(rec["name"], {"name": rec["name"], "profile": rec["profile"], "seconds": 0.0,
                                                "score": 0.0, "unsure": False})
        t["seconds"] += seconds
        t["score"] = max(t["score"], score)
        t["unsure"] = t["unsure"] or unsure

    def result(self, done: bool = False) -> dict:
        found = sorted((dict(v, seconds=round(v["seconds"], 1), score=round(v["score"], 3))
                        for v in self.names.values() if v["seconds"] >= MIN_SECONDS),
                       key=lambda v: v["seconds"], reverse=True)
        return {"voices": found, "pieces": self.pieces, "speech": round(self.speech, 1), "done": done}


def process(path: Path, recs: list, tally: Tally, embed=None, twin: dict | None = None) -> None:
    """One piece of the other side's track into the tally."""
    embed = embed or (lambda w: voices.embed([w]))
    twin = twins(recs) if twin is None else twin
    pieces = voices.speech_pieces(audio.decode(path))
    for w in windows(pieces):
        seconds = len(w) / audio.SR
        tally.speech += seconds
        vec = embed(w)
        if vec is None:
            continue
        found = match(vec, recs, twin)
        if found:
            rec, score, unsure = found
            tally.add(rec, seconds, score, unsure)
    tally.pieces += 1


def run(d: Path, log, poll: float = 2.0, parent: int | None = None) -> int:
    d = Path(d)
    parent = platform_support.parent_pid() if parent is None else parent
    recs = records(log)
    twin = twins(recs)
    tally = Tally()
    out = d / RESULT
    jsonfile.write_atomic(out, tally.result())
    if not recs:
        log("live voices: no saved voices, nothing to match")
        jsonfile.write_atomic(out, tally.result(done=True))
        return 0
    try:  # loaded now, at low priority during the call, so the last piece is quick after the stop
        voices._load()
    except voices.VoiceUnavailable as e:
        log(f"live voices: {e.message}")
        jsonfile.write_atomic(out, tally.result(done=True))
        return 0
    done: set = set()
    while True:
        if not d.is_dir():  # the app cleaned up
            return 0
        stopping = (d / STOP).exists()
        fresh = [p for p in sorted(d.glob(CHUNKS)) if p.name not in done]
        for p in fresh:
            try:
                process(p, recs, tally, twin=twin)
            except voices.VoiceUnavailable as e:
                log(f"live voices: {e.message}")
                jsonfile.write_atomic(out, tally.result(done=True))
                return 0
            except Exception as e:  # noqa: BLE001  one bad piece: skip it, keep the rest
                log(f"live voices: {p.name}: {type(e).__name__}: {e}")
            done.add(p.name)
            p.unlink(missing_ok=True)  # raw speech of the other side: not a moment longer than needed
            jsonfile.write_atomic(out, tally.result())
        if stopping and not fresh:
            break
        if platform_support.parent_pid() != parent:  # the app is gone
            break
        time.sleep(min(poll, 0.2) if stopping else poll)
    result = tally.result(done=True)
    jsonfile.write_atomic(out, result)
    log("live voices: " + (", ".join(f"{v['name']} {v['seconds']:.0f} s" for v in result["voices"]) or "none")
        + f" ({tally.pieces} pieces, {tally.speech:.0f} s of speech)")
    return 0


def read(d: Path) -> dict:
    """The tally as the app reads it (tests)."""
    try:
        return json.loads((Path(d) / RESULT).read_text())
    except (OSError, ValueError):
        return {}
