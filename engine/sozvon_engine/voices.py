"""Voice prints: name a remote voice the engine has heard before (docs/CONTRACT.md, "Voice prints").

A voice print is an L2-normalized wespeaker embedding (pyannote/wespeaker-voxceleb-resnet34-LM, the model
inside speaker-diarization-3.1, shipped in <data>/hf-cache) averaged over clean pieces of one person's speech.
Records live in <data>/voices/<id>.json (mode 600), written atomically under a flock on <data>/voices/.lock.
Deleted ids go to <data>/voices-deleted.json until sync deletes them on the own server.

Voice prints are biometric data: they never leave the Mac unless the user set up an own server.
"""
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

from . import accel, audio, config, jsonfile, paths, platform_support
from .i18n import t

EMBEDDING = "pyannote/wespeaker-voxceleb-resnet34-LM"
DIM = 256
# What a record's "model" says about its embedding. A record without the field is of this model.
MODEL = f"{EMBEDDING.split('/')[-1]}/{DIM}"
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
MIN_MIC_PERSON = 15.0    # seconds of speech a microphone cluster needs to count as a separate person
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
        platform_support.lock_exclusive(fd)
        yield
    finally:
        platform_support.unlock(fd)
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
    out = {"schema": SCHEMA, "id": vid, "name": name.strip(), "profile": "" if me else profile, "me": me,
           "embedding": [float(x) for x in emb], "seconds": float(sec),
           "updated_at": str(rec.get("updated_at") or "")}
    if rec.get("model") not in (None, ""):  # kept as is; absent stays absent (the older files and the server's)
        out["model"] = str(rec["model"])
    return out


def is_current(rec: dict) -> bool:
    """True for a voice print of the model in use (a record without "model" is of it)."""
    return rec.get("model", MODEL) == MODEL


_logged_foreign = False


def only_current(recs: list, log=None) -> list:
    """The records of the current model. Others stay untouched on disk; logged once per run (process)."""
    global _logged_foreign
    keep = [r for r in recs if is_current(r)]
    if len(keep) < len(recs) and log is not None and not _logged_foreign:
        _logged_foreign = True
        log(f"voices: {len(recs) - len(keep)} voice print(s) of another model skipped (they stay saved)")
    return keep


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
    if old and not is_current(old):  # prints of two models are never mixed
        raise ValueError("voice prints of different models can't be merged")
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
        recs = [r for r in load_all() if is_current(r)]  # other models' records are never merged or replaced
        if me and any(not r["me"] and r["name"] == name and r["profile"] == "" for r in recs):
            raise VoiceError(2, t("voice_me_name_taken", name=name))
        mine = next((r for r in recs if r["me"]), None) if me else None
        same = next((r for r in recs if r["name"] == name and r["profile"] == profile), None)
        target = mine or same
        emb_list, sec = merge_embeddings(None if replace else target, emb, seconds)
        rec = {"schema": SCHEMA, "id": target["id"] if target else uuid.uuid4().hex, "name": name,
               "profile": profile, "me": bool(me or (target and target["me"])), "embedding": emb_list,
               "seconds": sec, "updated_at": now(), "model": MODEL}
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
    """sha256 over the canonical JSON of what syncs (both sides normalize numbers the same way).
    "model" is not part of it: the own server doesn't store it, and the hash of older records stays the same."""
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
_inference_device = None


def available() -> bool:
    return paths.engine_dir().wespeaker_cache.is_dir() or bool(config.load().hf_token)


def _device() -> str:
    """On the Mac the CPU, as the contract says; on Windows the install's choice, this model is most of pyannote's time."""
    return accel.torch_device("voices") if platform_support.SYSTEM == "win32" else "cpu"


def _load():
    """The embedding model, once per process, on the CPU (small and fast enough; no GPU memory)."""
    global _inference, _inference_device
    if _inference is not None and _inference_device == _device():
        return _inference
    if not available():
        raise VoiceUnavailable(t("voice_no_model"))
    settings = config.load()
    try:
        import torch
        accel.apply_thread_limit()
        from pyannote.audio import Inference, Model
        model = Model.from_pretrained(EMBEDDING, token=settings.hf_token or None)
    except ImportError:
        raise
    except Exception as e:  # noqa: BLE001  a broken or missing cache: the caller goes on without voices
        raise VoiceUnavailable(t("voice_model_failed", err=e)) from e
    if model is None:
        raise VoiceUnavailable(t("voice_no_model"))
    model.eval()
    _inference_device = _device()
    _inference = Inference(model, window="whole", device=torch.device(_inference_device))
    return _inference


def embed(pieces: list, sr: int = audio.SR) -> np.ndarray | None:
    """Speech pieces of one voice -> L2-normalized embedding (windows weighted by length), None if nothing usable."""
    return accel.with_cpu_fallback("voices", lambda: _embed(pieces, sr), drop=_drop_model)


def _drop_model() -> None:
    global _inference
    _inference = None


def _embed(pieces: list, sr: int) -> np.ndarray | None:
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


_LATIN = str.maketrans({"а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z",
                        "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
                        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sch",
                        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya"})


def same_name(a: str, b: str) -> bool:
    """One name, whatever the case and the alphabet ("Борис", "boris"). Same rule as Voices.sameName in the app."""
    x, y = (" ".join(s.lower().split()).translate(_LATIN) for s in (a, b))
    return bool(x) and x == y


def is_me_label(label: str, settings: config.Settings | None = None) -> bool:
    """The user's label in a transcript. The name in Settings may be empty or spelled differently from the
    label of an older call, so the name of the user's own voice print counts too (of any model: a name is a name)."""
    settings = settings or config.load()
    known = [settings.me or t("me"), t("me"), "me"] + [r["name"] for r in load_all() if r["me"]]
    return any(same_name(label, name) for name in known)


def _recorded_track(call: dict, label: str) -> str:
    """The track another person's lines came from: call.json "speaker_tracks", which only a call with someone at the
    user's microphone has. Without it, the system track. A person on both tracks, or on none we know of, is refused:
    a voice print read from the wrong track would hold somebody else's voice."""
    known = call.get("speaker_tracks")
    if known is None:
        return "system"
    track = known.get(label) if isinstance(known, dict) else None
    if track not in ("mic", "system"):
        raise VoiceError(2, t("voice_two_tracks", label=label))
    return track


def enroll_call(d: Path, label: str, name: str, profile: str = "", me: bool = False) -> dict:
    """The paragraphs of one speaker in a call: mic.m4a for the user, system.m4a for remote speakers, the
    microphone for a person found on it (_recorded_track).

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
    if not me and is_me_label(label):  # the user's own voice comes from the sample in Settings
        raise VoiceError(2, t("voice_no_speaker", label=label))
    spans, _ = call_paragraphs(d, label)
    if not spans:
        raise VoiceError(2, t("voice_no_speaker", label=label))
    files = tracks_stage.track_files(d)
    mine = is_me_label(label)
    key = ("mic" if "mic" in files else "system") if mine else _recorded_track(call, label)
    if key not in files:
        raise VoiceError(2, t("err_no_audio"))
    delay = tracks_stage.delays(calls.audio_meta(d, call)).get(key, 0.0)
    source = files[key]
    if key == "mic" and not mine and (d / tracks_stage.CLEAN_MIC).is_file():
        source, delay = d / tracks_stage.CLEAN_MIC, 0.0  # free of the other side's echo, aligned to the call's start
    shifted = [(max(0.0, s - delay), e - delay) for s, e in spans if e - delay > MIN_PIECE]
    pieces = _limit(speech_of_spans(source, longest(shifted)))
    sec = seconds_of(pieces)
    if sec < MIN_CALL_SPEECH:
        raise VoiceError(2, t("voice_too_short", sec=_shown(sec), need=MIN_CALL_SPEECH))
    emb = embed(pieces)
    if emb is None:
        raise VoiceError(2, t("voice_too_short", sec=0.0, need=MIN_CALL_SPEECH))
    return store(name, profile, me, emb, sec)


# --- matching ---

def candidates(profile: str, with_me: bool, log=None) -> list:
    """Records a call of this project can match: its project's, the ones without a project, and (with_me) mine.
    Only of the current model."""
    out = []
    for r in only_current(load_all(), log):
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


def cluster_vectors(path, diar: list, known: dict | None = None) -> dict:
    """{raw label: embedding, or None for a cluster with too little clean speech} of one track's clusters.

    known: what this run has embedded so far, by (track, raw label). It is read and filled in, so one voice
    is embedded once however many steps compare it.
    """
    known = {} if known is None else known
    out = {}
    for label in dict.fromkeys(lab for *_, lab in diar):
        key = (str(path), label)
        if key not in known:
            pieces = _limit(speech_of_spans(path, longest(clean_spans(diar, label))))
            known[key] = embed(pieces) if seconds_of(pieces) >= MIN_MATCH_SPEECH else None
        out[label] = known[key]
    return out


def identify(path, diar: list, profile: str, me: str | None, log, known: dict | None = None) -> dict:
    """Pipeline step: raw diarization label -> stored name for the voices of this track.

    me: the user's label when the user's own voice can be in this track (a single-track recording), else None.
    No stored voices: nothing is loaded at all. known: see cluster_vectors. -> {raw label: name}.
    """
    records = candidates(profile, me is not None, log)
    if not records or not diar:
        return {}
    found = match(cluster_vectors(path, diar, known), records)
    return {label: (me if rec["me"] and me else rec["name"], score) for label, (rec, score) in found.items()}


def _merge_similar(labels: list, vecs: dict, speech: dict) -> dict:
    """{raw label: label of its group} for unknown voices that are alike, directly or through another one.

    Voices far from the microphone blur together and diarization deals them out at random, so its clusters are
    not people there: one label for them is the truth we have. The group is named after its longest cluster.
    """
    group = {k: k for k in labels}

    def root(k):
        while group[k] != k:
            k = group[k]
        return k
    for i, a in enumerate(labels):
        for b in labels[i + 1:]:
            if float(unit(vecs[a]) @ unit(vecs[b])) >= THRESHOLD:
                group[root(b)] = root(a)
    longest_of: dict = {}
    for k in labels:
        r = root(k)
        if r not in longest_of or speech[k] > speech[longest_of[r]]:
            longest_of[r] = k
    return {k: longest_of[root(k)] for k in labels}


def mic_people(path, diarize_mic, system_path, system_diar: list, profile: str, log, known: dict | None = None) -> tuple:
    """Pipeline step: who else speaks at the user's microphone. -> (microphone diarization, {raw label: name or None}).

    Only clusters that are separate people are in the result (None: nobody's voice print matched); every other
    cluster is the user. Unknown voices that are alike come back as one cluster. The result is empty when there is no print of the user or no cluster matches it.
    diarize_mic() is called at most once, and only when the user's own print exists. Exceptions reach the caller,
    which falls back to labeling everything as the user.
    """
    mine = next((r for r in only_current(load_all(), log) if r["me"]), None)
    if mine is None:
        log(t("log_mic_no_print"))
        return [], {}
    diar = diarize_mic()
    speech: dict = {}
    for s, e, label in diar:
        speech[label] = speech.get(label, 0.0) + e - s
    if len(speech) < 2 or max(speech.values()) < MIN_MIC_PERSON:  # nobody to tell apart: nothing to embed
        return diar, {}
    vecs = {k: v for k, v in cluster_vectors(path, diar, known).items() if v is not None}
    found = match(vecs, candidates(profile, True, log))
    own = unit(mine["embedding"])

    def is_mine(label):
        # match gives a name to one cluster only: the user split into two clusters is still the user.
        return float(unit(vecs[label]) @ own) >= THRESHOLD and (label not in found or found[label][0]["me"])
    if not any(is_mine(k) for k in vecs):
        log(t("log_mic_no_match"))
        return [], {}
    people = [k for k in vecs if not is_mine(k) and speech[k] >= MIN_MIC_PERSON]
    if not people:
        return diar, {}
    # Any remote voice is enough here, so a threshold without a margin: the margin only picks between names.
    remote = [unit(v) for v in cluster_vectors(system_path, system_diar, known).values() if v is not None]
    echo = {k for k in people if any(float(unit(vecs[k]) @ v) >= THRESHOLD for v in remote)}
    if echo:
        log(t("log_mic_echo", n=len(echo)))
    kept = [k for k in people if k not in echo]
    one_label = _merge_similar([k for k in kept if k not in found], vecs, speech)
    return ([(s, e, one_label.get(label, label)) for s, e, label in diar],
            {k: found[k][0]["name"] if k in found else None for k in kept if one_label.get(k, k) == k})


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
        if not (is_current(here) and is_current(stored)):  # another model: keep the record here as it is
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
    if rec is None or not is_current(rec):
        return False
    with locked():
        recs = load_all()
        same = next((r for r in recs if r["id"] == rec["id"]), None)
        if same is not None:
            if not is_current(same):  # a conflict between models: the record here wins
                return False
            if timestamp(same["updated_at"]) >= timestamp(rec["updated_at"]):
                return False
            save(rec)
            return True
        if rec["id"] in tombstones():
            return False
        clash = next((r for r in recs if is_current(r) and ((r["name"] == rec["name"] and r["profile"] == rec["profile"])
                                                           or (r["me"] and rec["me"]))), None)
        if clash is None:
            save(rec)
            return True
        emb, sec = merge_embeddings(clash, rec["embedding"], rec["seconds"])
        save({**clash, "embedding": emb, "seconds": sec, "updated_at": now()})
        tombs = tombstones()
        _tombstone([rec["id"]], tombs)
        _write_tombstones(tombs)
        return False
