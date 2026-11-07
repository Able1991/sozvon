"""Voice prints: name a remote voice the engine has heard before (docs/CONTRACT.md, "Voice prints").

A voice print is an L2-normalized wespeaker embedding (pyannote/wespeaker-voxceleb-resnet34-LM, the model
inside speaker-diarization-3.1, shipped in <data>/hf-cache) averaged over clean pieces of one person's speech.
Records live in <data>/voices/<id>.json (mode 600), written atomically under a flock on <data>/voices/.lock.
Deleted ids go to <data>/voices-deleted.json until sync deletes them on the own server.

Voice prints are biometric data: they never leave the Mac unless the user set up an own server.
"""
import fcntl
import hashlib
import json
import math
import os
import re
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

import numpy as np

from . import audio, config, jsonfile, paths
from .i18n import t

EMBEDDING = "pyannote/wespeaker-voxceleb-resnet34-LM"
DIM = 256
SCHEMA = 1
ID_RE = re.compile(r"^[0-9a-f]{32}$")

MIN_FILE_SPEECH = 8.0    # seconds of speech for an enrollment from a recording of one person
MIN_CALL_SPEECH = 4.0    # seconds of speech for an enrollment from a call
MAX_SPEECH = 60.0        # seconds of speech embedded for one voice (longest clean pieces first)
WEIGHT_CAP = 300.0       # seconds: an old record never outweighs new speech forever
MAX_SECONDS = 10000.0    # the server accepts at most this many
MAX_NAME = 80

THRESHOLD = 0.5          # cosine: wespeaker same person ~0.7-0.95, different people ~0.1-0.4
MARGIN = 0.1             # above the second best candidate
MIN_MATCH_SPEECH = 2.0   # seconds of clean speech a cluster needs to be matched at all
WINDOW = 10.0            # seconds per embedding window (memory stays flat on long pieces)
MIN_PIECE = 0.5          # seconds


class VoiceError(Exception):
    """code: the RESULT protocol exit code (2 bad input, 4 model missing, 5 ffmpeg, 1 other)."""

    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class VoiceUnavailable(VoiceError):
    """No embedding model (no pyannote models, no token)."""

    def __init__(self, message: str):
        super().__init__(4, message)


# --- storage ---

def voices_dir() -> Path:
    return paths.engine_dir().voices


def deleted_file() -> Path:
    return paths.engine_dir().voices_deleted


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


@contextmanager
def locked():
    """Exclusive flock on <data>/voices/.lock for any read-modify-write of voice records and tombstones."""
    d = voices_dir()
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    fd = os.open(d / ".lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def unit(v) -> np.ndarray:
    v = np.asarray(v, dtype=np.float64).reshape(-1)
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


def valid(rec) -> dict | None:
    """A clean record, or None if it is not one (ignored by readers)."""
    if not isinstance(rec, dict):
        return None
    vid, name, profile = rec.get("id"), rec.get("name"), rec.get("profile", "")
    emb, sec = rec.get("embedding"), rec.get("seconds")
    if not (isinstance(vid, str) and ID_RE.match(vid)):
        return None
    if not isinstance(name, str) or not name.strip() or len(name.strip()) > MAX_NAME:
        return None
    if not isinstance(profile, str) or (profile and not re.fullmatch(r"[a-z0-9_-]{1,64}", profile)):
        return None
    if not isinstance(emb, list) or len(emb) != DIM:
        return None
    if not all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) for x in emb):
        return None
    if not isinstance(sec, (int, float)) or isinstance(sec, bool) or not 0 <= sec <= MAX_SECONDS:
        return None
    me = rec.get("me") is True
    return {"schema": SCHEMA, "id": vid, "name": name.strip(), "profile": "" if me else profile, "me": me,
            "embedding": [float(x) for x in emb], "seconds": float(sec),
            "updated_at": str(rec.get("updated_at") or "")}


def load_all() -> list:
    """Every valid record, sorted by name then id."""
    out = []
    d = voices_dir()
    if not d.is_dir():
        return out
    for f in d.glob("*.json"):
        rec = valid(jsonfile.read(f, default=None))
        if rec and f.stem == rec["id"]:
            out.append(rec)
    return sorted(out, key=lambda r: (r["name"].lower(), r["profile"], r["id"]))


def _file(vid: str) -> Path:
    return voices_dir() / f"{vid}.json"


def save(rec: dict) -> None:
    """Write one record atomically (mode 600). The caller holds locked()."""
    rec = valid(rec)
    if rec is None:
        raise ValueError("invalid voice record")
    jsonfile.write_atomic(_file(rec["id"]), rec)
    os.chmod(_file(rec["id"]), 0o600)


def _remove(vid: str) -> bool:
    try:
        _file(vid).unlink()
        return True
    except FileNotFoundError:
        return False


def tombstones() -> dict:
    """id -> deleted at, of voices deleted here that sync has not deleted on the server yet."""
    data = jsonfile.read(deleted_file(), default={}) or {}
    items = data.get("voices") if isinstance(data.get("voices"), list) else []
    return {v["id"]: str(v.get("at") or "") for v in items
            if isinstance(v, dict) and isinstance(v.get("id"), str) and ID_RE.match(v["id"])}


def _write_tombstones(tombs: dict) -> None:
    if not tombs and not deleted_file().exists():
        return
    jsonfile.write_atomic(deleted_file(), jsonfile.with_schema(
        {"voices": [{"id": k, "at": v} for k, v in sorted(tombs.items())]}))


def _tombstone(ids, tombs: dict) -> None:
    at = now()
    for vid in ids:
        tombs.setdefault(vid, at)


def forget_tombstones(ids) -> None:
    """Drop ids from voices-deleted.json (deleted on the server)."""
    drop = set(ids)
    if not drop:
        return
    with locked():
        tombs = tombstones()
        if drop & set(tombs):
            _write_tombstones({k: v for k, v in tombs.items() if k not in drop})


def delete(vid: str | None = None, everything: bool = False) -> int:
    """Delete one record (or all) and record tombstones for sync. -> how many were deleted."""
    with locked():
        recs = load_all()
        ids = [r["id"] for r in recs] if everything else [vid] if vid else []
        tombs = tombstones()
        gone = [i for i in ids if _remove(i)]
        # An id the server may still hold gets a tombstone even when the file is gone already.
        _tombstone([i for i in ids if isinstance(i, str) and ID_RE.match(i)], tombs)
        _write_tombstones(tombs)
    return len(gone)


def summary(rec: dict) -> dict:
    return {k: rec[k] for k in ("id", "name", "profile", "me", "seconds", "updated_at")}


def merge_embeddings(old: dict | None, emb, seconds: float) -> tuple[list, float]:
    """Weighted average by speech seconds (each side capped at WEIGHT_CAP), re-normalized."""
    new = unit(emb)
    if not old:
        return [float(x) for x in new], float(seconds)
    w_old, w_new = min(old["seconds"], WEIGHT_CAP), min(seconds, WEIGHT_CAP)
    if w_old + w_new <= 0:
        return [float(x) for x in new], float(seconds)
    mixed = unit(unit(old["embedding"]) * w_old + new * w_new)
    return [float(x) for x in mixed], min(MAX_SECONDS, float(old["seconds"]) + float(seconds))


def store(name: str, profile: str, me: bool, emb, seconds: float, replace: bool = False) -> dict:
    """Enroll speech into the record of (name, profile); with me, into the user's own record.

    replace: a fresh recording of one person replaces the record's voice print instead of being merged.
    Only one record may have "me": true (profile ""). A "me" enrollment under the name of another person's
    record (profile "") is refused: folding it would lose that person's voice print.
    """
    name = " ".join(str(name).split())
    if not name or len(name) > MAX_NAME:
        raise VoiceError(2, t("voice_bad_name", n=MAX_NAME))
    profile = "" if me else (profile or "")
    with locked():
        recs = load_all()
        if me and any(not r["me"] and r["name"] == name and r["profile"] == "" for r in recs):
            raise VoiceError(2, t("voice_me_name_taken", name=name))
        mine = next((r for r in recs if r["me"]), None) if me else None
        same = next((r for r in recs if r["name"] == name and r["profile"] == profile), None)
        target = mine or same
        emb_list, sec = merge_embeddings(None if replace else target, emb, seconds)
        rec = {"schema": SCHEMA, "id": target["id"] if target else uuid.uuid4().hex, "name": name,
               "profile": profile, "me": bool(me or (target and target["me"])), "embedding": emb_list,
               "seconds": sec, "updated_at": now()}
        save(rec)
        tombs = tombstones()
        extra = [r["id"] for r in recs if r["id"] != rec["id"] and (
            (r["name"] == name and r["profile"] == profile) or (rec["me"] and r["me"]))]
        if extra:
            for i in extra:
                _remove(i)
            _tombstone(extra, tombs)
            _write_tombstones(tombs)
        elif rec["id"] in tombs:  # enrolled again after a delete of the same id: never deleted by sync
            _write_tombstones({k: v for k, v in tombs.items() if k != rec["id"]})
    return valid(rec)


def content_hash(rec: dict) -> str:
    """sha256 over the canonical JSON of what syncs (both sides normalize numbers the same way)."""
    r = valid(rec) or {}
    canon = json.dumps({k: r.get(k) for k in ("id", "name", "profile", "me", "embedding", "seconds", "updated_at")},
                       sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


# --- speech and embeddings ---

def speech_pieces(x: np.ndarray, sr: int = audio.SR) -> list:
    """Speech parts of a mono signal (rough energy VAD, 30 ms frames, short gaps bridged). -> [array]."""
    if len(x) == 0:
        return []
    peak = float(np.percentile(np.abs(x), 99.5))
    if 1e-4 < peak < 0.1:  # a quiet track: level it like tracks.boost before the energy threshold
        x = np.clip(x * min(0.5 / peak, 31.6), -1.0, 1.0)
    frame = int(sr * 0.03)
    n = len(x) // frame
    if n == 0:
        return []
    rms = np.sqrt((x[: n * frame].reshape(n, frame).astype(np.float64) ** 2).mean(axis=1))
    active = rms > 0.01
    spans, start, quiet = [], None, 0
    gap = int(0.3 / 0.03)
    for i, a in enumerate(list(active) + [False] * (gap + 1)):
        if a:
            if start is None:
                start = i
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet > gap:
                spans.append((start, i - quiet + 1))
                start, quiet = None, 0
    return [x[s * frame:e * frame] for s, e in spans if (e - s) * 0.03 >= MIN_PIECE]


def seconds_of(pieces: list, sr: int = audio.SR) -> float:
    return float(sum(len(p) for p in pieces)) / sr


_inference = None


def available() -> bool:
    return paths.engine_dir().wespeaker_cache.is_dir() or bool(config.load().hf_token)


def _load():
    """The embedding model, once per process, on the CPU (small and fast enough; no GPU memory)."""
    global _inference
    if _inference is not None:
        return _inference
    if not available():
        raise VoiceUnavailable(t("voice_no_model"))
    settings = config.load()
    try:
        import torch
        if settings.threads:
            torch.set_num_threads(settings.threads)
        from pyannote.audio import Inference, Model
        model = Model.from_pretrained(EMBEDDING, token=settings.hf_token or None)
    except ImportError:
        raise
    except Exception as e:  # noqa: BLE001  a broken or missing cache: the caller goes on without voices
        raise VoiceUnavailable(t("voice_model_failed", err=e)) from e
    if model is None:
        raise VoiceUnavailable(t("voice_no_model"))
    model.eval()
    _inference = Inference(model, window="whole", device=torch.device("cpu"))
    return _inference


def embed(pieces: list, sr: int = audio.SR) -> np.ndarray | None:
    """Speech pieces of one voice -> L2-normalized embedding (windows weighted by length), None if nothing usable."""
    import torch
    inf = _load()
    vecs, weights = [], []
    step = int(WINDOW * sr)
    for p in pieces:
        for i in range(0, len(p), step):
            w = p[i:i + step]
            if len(w) < MIN_PIECE * sr:
                continue
            with torch.inference_mode():
                v = np.asarray(inf({"waveform": torch.from_numpy(np.array(w, dtype=np.float32)).unsqueeze(0),
                                    "sample_rate": sr}), dtype=np.float64).reshape(-1)
            if v.shape[0] == DIM and np.all(np.isfinite(v)) and np.linalg.norm(v) > 0:
                vecs.append(unit(v))
                weights.append(len(w))
    if not vecs:
        return None
    return unit(np.average(np.stack(vecs), axis=0, weights=weights))


def longest(spans: list, limit: float = MAX_SPEECH) -> list:
    """The longest spans (start, end) until their total reaches limit; the last one is cut to fit."""
    out, total = [], 0.0
    for s, e in sorted(spans, key=lambda p: p[1] - p[0], reverse=True):
        if total >= limit:
            break
        e = min(e, s + (limit - total))
        if e - s >= MIN_PIECE:
            out.append((s, e))
            total += e - s
    return sorted(out)


def clean_spans(diar: list, label) -> list:
    """Turns of one voice that no other voice overlaps (the parts that do are cut away)."""
    others = sorted((s, e) for s, e, lab in diar if lab != label)
    out = []
    for s, e, lab in diar:
        if lab != label:
            continue
        pieces = [(s, e)]
        for os_, oe in others:
            nxt = []
            for ps, pe in pieces:
                if oe <= ps or os_ >= pe:
                    nxt.append((ps, pe))
                    continue
                if os_ > ps:
                    nxt.append((ps, os_))
                if oe < pe:
                    nxt.append((oe, pe))
            pieces = nxt
        out += [(ps, pe) for ps, pe in pieces if pe - ps >= MIN_PIECE]
    return out


def speech_of_spans(path, spans: list) -> list:
    """Decode only these spans of a file and keep their speech parts."""
    pieces = []
    for s, e in spans:
        pieces += speech_pieces(audio.decode_span(path, s, e - s))
    return pieces


# --- enrollment ---

def enroll_file(path: Path, name: str, profile: str = "", me: bool = False, add: bool = False) -> dict:
    """A recording of one person (the user's sample in Settings). Needs MIN_FILE_SPEECH seconds of speech.
    A new sample replaces the voice print; with `add` it is merged in (one more sample, e.g. in another language)."""
    path = Path(path)
    if not path.is_file():
        raise VoiceError(2, t("voice_no_file", path=path))
    pieces = speech_pieces(audio.decode(path))
    sec = seconds_of(pieces)
    if sec < MIN_FILE_SPEECH:
        raise VoiceError(2, t("voice_too_short", sec=_shown(sec), need=MIN_FILE_SPEECH))
    pieces = _limit(pieces)
    emb = embed(pieces)
    if emb is None:
        raise VoiceError(2, t("voice_too_short", sec=0.0, need=MIN_FILE_SPEECH))
    return store(name, profile, me, emb, seconds_of(pieces), replace=not add)


def _shown(sec: float) -> float:
    """Seconds for a "not enough speech" message, rounded down: 3.97 s is never shown as the 4 s it lacks."""
    return math.floor(sec * 10) / 10


def _limit(pieces: list, limit: float = MAX_SPEECH, sr: int = audio.SR) -> list:
    """The longest pieces up to limit seconds."""
    out, total = [], 0
    for p in sorted(pieces, key=len, reverse=True):
        if total >= limit * sr:
            break
        p = p[: int(limit * sr - total)]
        out.append(p)
        total += len(p)
    return out


def call_paragraphs(d: Path, label: str) -> tuple[list, list]:
    """transcript.txt -> (spans of LABEL's paragraphs that overlap no other speaker's, all paragraphs)."""
    from .pipeline import render
    f = Path(d) / "transcript.txt"
    if not f.is_file():
        raise VoiceError(2, t("err_no_transcript"))
    paras = render.parse_txt(f.read_text(encoding="utf-8"))
    mine = [(s, e) for s, e, _, who in paras if who == label and e - s >= MIN_PIECE]
    others = [(s, e) for s, e, _, who in paras if who != label]
    clean = [(s, e) for s, e in mine if not any(os_ < e and s < oe for os_, oe in others)]
    return clean, paras


def is_me_label(label: str, settings: config.Settings | None = None) -> bool:
    settings = settings or config.load()
    me = settings.me or t("me")
    return label == me or label.lower() == "me"


def enroll_call(d: Path, label: str, name: str, profile: str = "", me: bool = False) -> dict:
    """The paragraphs of one speaker in a call: mic.m4a for the user, system.m4a for remote speakers.

    Times in transcript.txt are on the shared timeline (tracks.delays): a track that started later is read
    that much earlier. Needs MIN_CALL_SPEECH seconds of clean speech; merges into the existing record.
    """
    from . import calls
    from .pipeline import tracks as tracks_stage
    d = Path(d)
    if not d.is_dir():
        raise VoiceError(2, t("err_no_dir", path=d))
    try:
        call = calls.read_call(d, strict=True)
    except jsonfile.JsonFileError as e:
        raise VoiceError(2, t("err_bad_call", err=e)) from e
    spans, _ = call_paragraphs(d, label)
    if not spans:
        raise VoiceError(2, t("voice_no_speaker", label=label))
    files = tracks_stage.track_files(d)
    key = "mic" if is_me_label(label) and "mic" in files else "system"
    if key not in files:
        raise VoiceError(2, t("err_no_audio"))
    delay = tracks_stage.delays(calls.audio_meta(d, call)).get(key, 0.0)
    shifted = [(max(0.0, s - delay), e - delay) for s, e in spans if e - delay > MIN_PIECE]
    pieces = _limit(speech_of_spans(files[key], longest(shifted)))
    sec = seconds_of(pieces)
    if sec < MIN_CALL_SPEECH:
        raise VoiceError(2, t("voice_too_short", sec=_shown(sec), need=MIN_CALL_SPEECH))
    emb = embed(pieces)
    if emb is None:
        raise VoiceError(2, t("voice_too_short", sec=0.0, need=MIN_CALL_SPEECH))
    return store(name, profile, me, emb, sec)


# --- matching ---

def candidates(profile: str, with_me: bool) -> list:
    """Records a call of this project can match: its project's, the ones without a project, and (with_me) mine."""
    out = []
    for r in load_all():
        if r["me"]:
            if with_me:
                out.append(r)
        elif r["profile"] in ("", profile):
            out.append(r)
    return out


def match(clusters: dict, records: list, threshold: float = THRESHOLD, margin: float = MARGIN) -> dict:
    """{cluster key: embedding} x records -> {cluster key: (record, score)}.

    A pair counts when its cosine is at least threshold and at least margin above the cluster's second best
    candidate name. Then the best pairs win greedily, so no two clusters get the same name.
    """
    by_name: dict = {}
    for r in records:  # one candidate per name: the same person in the project and without one
        by_name.setdefault(r["name"], []).append(r)
    pairs = []
    for key, vec in clusters.items():
        if vec is None:
            continue
        v = unit(vec)
        scored = []
        for name, recs in by_name.items():
            best = max(recs, key=lambda r: float(v @ unit(r["embedding"])))
            scored.append((float(v @ unit(best["embedding"])), name, best))
        scored.sort(key=lambda x: x[0], reverse=True)
        if not scored:
            continue
        top = scored[0]
        second = scored[1][0] if len(scored) > 1 else -1.0
        if top[0] >= threshold and top[0] - second >= margin:
            pairs.append((top[0], key, top[1], top[2]))
    out, used = {}, set()
    for score, key, name, rec in sorted(pairs, key=lambda p: p[0], reverse=True):
        if key in out or name in used:
            continue
        out[key] = (rec, score)
        used.add(name)
    return out


def identify(path, diar: list, profile: str, me: str | None, log) -> dict:
    """Pipeline step: raw diarization label -> stored name for the voices of this track.

    me: the user's label when the user's own voice can be in this track (a single-track recording), else None.
    No stored voices: nothing is loaded at all. -> {raw label: name}.
    """
    records = candidates(profile, me is not None)
    if not records or not diar:
        return {}
    clusters = {}
    for label in dict.fromkeys(lab for *_, lab in diar):
        pieces = _limit(speech_of_spans(path, longest(clean_spans(diar, label))))
        if seconds_of(pieces) < MIN_MATCH_SPEECH:
            continue
        clusters[label] = pieces
    if not clusters:
        return {}
    vecs = {label: embed(p) for label, p in clusters.items()}
    found = match(vecs, records)
    return {label: (me if rec["me"] and me else rec["name"], score) for label, (rec, score) in found.items()}


# --- sync helpers (remote.py) ---

def timestamp(s) -> float:
    """ISO 8601 UTC ("...Z", with or without milliseconds) -> epoch seconds; unparsable -> 0."""
    from datetime import datetime
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def drop_local(tombs: dict) -> int:
    """Delete records here because the server deleted them (no tombstone: the server has one).

    tombs: id -> the server tombstone's time. Each record is checked again under the lock: one changed here
    after the tombstone (an enrollment while the sync ran) is kept and goes up."""
    with locked():
        n = 0
        for vid, at in tombs.items():
            rec = valid(jsonfile.read(_file(vid), default=None)) if ID_RE.match(vid) else None
            if rec is not None and timestamp(rec["updated_at"]) > timestamp(at):
                continue
            n += 1 if _remove(vid) else 0
        return n


def merge_remote(stored: dict, mine: dict) -> dict | None:
    """The server refused this Mac's record (409): it holds a newer one of the same id with another print.
    -> the merged record (the server's name and flags, both prints by merge_embeddings, a time newer than
    both), stored here; None when the record here changed since this sync read it (the next sync decides)."""
    with locked():
        here = valid(jsonfile.read(_file(mine["id"]), default=None))
        if here is None or timestamp(here["updated_at"]) > timestamp(mine["updated_at"]):
            return None
        emb, sec = merge_embeddings(stored, mine["embedding"], mine["seconds"])
        at = now()
        if timestamp(at) <= timestamp(stored["updated_at"]):
            at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(timestamp(stored["updated_at"])) + 1))
        rec = valid({**stored, "embedding": emb, "seconds": sec, "updated_at": at})
        save(rec)
        return rec


def accept_remote(rec: dict) -> bool:
    """Store a record from the server. -> True if stored as is.

    Never replaces a newer record here. When another record here holds the same (name, profile), or both are
    "me", the server's voice print is folded into the one here (which is then newer and goes up) and the
    server's id gets a tombstone, so both Macs end up with one record.
    """
    rec = valid(rec)
    if rec is None:
        return False
    with locked():
        recs = load_all()
        same = next((r for r in recs if r["id"] == rec["id"]), None)
        if same is not None:
            if timestamp(same["updated_at"]) >= timestamp(rec["updated_at"]):
                return False
            save(rec)
            return True
        if rec["id"] in tombstones():
            return False
        clash = next((r for r in recs if (r["name"] == rec["name"] and r["profile"] == rec["profile"])
                      or (r["me"] and rec["me"])), None)
        if clash is None:
            save(rec)
            return True
        emb, sec = merge_embeddings(clash, rec["embedding"], rec["seconds"])
        save({**clash, "embedding": emb, "seconds": sec, "updated_at": now()})
        tombs = tombstones()
        _tombstone([rec["id"]], tombs)
        _write_tombstones(tombs)
        return False
