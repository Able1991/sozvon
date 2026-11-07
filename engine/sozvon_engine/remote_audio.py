"""Call audio on the own server (server 0.4.0+, docs/CONTRACT.md section 3, "Audio").

Tracks (mic.m4a, system.m4a) go up in chunks of CHUNK bytes, stored in D1 (no R2: it needs a payment card):
  GET    {url}/api/calls/{id}/audio                       -> {"tracks": [{track, size, chunks, sha256, updated_at, start}],
                                                              "pending": [{track, sha256, chunks: [{idx, size}]}],
                                                              "audio_removed_at": null | time}
  PUT    {url}/api/calls/{id}/audio/{track}/{idx}         <- raw bytes, X-Sozvon-Sha256: <sha256 of the whole track>
                                                           -> 204; 507 when the server's audio storage is full
  POST   {url}/api/calls/{id}/audio/{track}/commit        <- {"size", "chunks", "sha256", "start"?} -> 204
                                                           (409: chunks missing)
  GET    {url}/api/calls/{id}/audio/{track}/{idx}         -> raw bytes
  DELETE {url}/api/calls/{id}/audio                       -> 204, and the server marks the call's audio removed:
                                                           chunk PUTs and commits for it answer 410 from then on
GET /api/calls lists "audio": {track: sha256} per call that has some, and "audio_removed_at" per call so marked.

Files are streamed chunk by chunk: a track is never read into memory whole. An interrupted upload resumes from the
chunks the server already staged. "start" is the track's start offset in seconds relative to the earlier track
(call.json audio mic_start / system_start minus the smaller one): a Mac that downloads the tracks writes it as
{track}_start, the same offsets tracks.delays and the app's player use (absolute host times mean nothing there).

Removal is a fact on the server: a call whose audio the app removed (call.json "audio_removed_at") sends the DELETE
once, and from then on no Mac uploads or downloads that call's audio. A Mac that still has its own tracks keeps
them (its own retention setting decides), it just never sends them again.
"""
import hashlib
import os
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from . import calls, jsonfile, paths
from .i18n import t

CHUNK = 1_900_000
TRACKS = ("mic", "system")
MIN_TRACK_BYTES = 1024  # as pipeline.tracks: smaller files hold no audio
CHUNK_TIMEOUT = 120  # seconds per chunk: 1.9 MB over a slow uplink
MAX_START = 86_400  # seconds: the largest start offset the server stores
STALE_DOWNLOAD = 15 * 60  # seconds: a .download-*.m4a untouched this long was left by an interrupted download


def _remote():
    from . import remote
    return remote


class StorageFull(Exception):
    """507 from the server: its free storage for audio is full."""


def _raw(srv, method: str, path: str, data: bytes | None = None, headers: dict | None = None,
         missing_ok: bool = False):
    """A request with a raw body or reply. -> (status, bytes). 507 raises StorageFull."""
    remote = _remote()
    req = urllib.request.Request(srv.url + path, data=data, method=method)
    req.add_header("User-Agent", remote.USER_AGENT)
    req.add_header("Authorization", f"Bearer {srv.password}")
    if data is not None:
        req.add_header("Content-Type", "application/octet-stream")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=CHUNK_TIMEOUT) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise remote.RemoteError(2, t("remote_auth")) from None
        if e.code == 507:
            raise StorageFull() from None
        if missing_ok and e.code in (404, 405, 410):
            return e.code, b""
        if e.code == 410:
            raise remote.Gone(1, t("remote_http", code=e.code, method=method, path=path)) from None
        raise remote.RemoteError(1, t("remote_http", code=e.code, method=method, path=path)) from None
    except (urllib.error.URLError, OSError) as e:
        raise remote.Unreachable(1, t("remote_unreachable", err=getattr(e, "reason", e))) from None


def _audio_path(cid: str, *rest) -> str:
    return "/api/calls/" + urllib.parse.quote(cid, safe="") + "/audio" + "".join(
        "/" + urllib.parse.quote(str(p), safe="") for p in rest)


# --- local tracks and their hashes (<data>/server-audio.json, a cache keyed by call id and track) ---

def cache_file() -> Path:
    return paths.data_dir() / "server-audio.json"


def local_tracks(d: Path) -> dict:
    """{track: file} of the tracks in a call folder."""
    out = {}
    for key in TRACKS:
        f = Path(d) / f"{key}.m4a"
        if f.is_file() and f.stat().st_size >= MIN_TRACK_BYTES:
            out[key] = f
    return out


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while block := f.read(1 << 20):
            h.update(block)
    return h.hexdigest()


class Hashes:
    """sha256 of local tracks, recomputed only when a file's size or mtime changed."""

    def __init__(self):
        data = jsonfile.read(cache_file(), default={}) or {}
        files = data.get("files") if isinstance(data.get("files"), dict) else {}
        self.files = {k: v for k, v in files.items() if isinstance(v, dict)}
        self.changed = False

    def of(self, cid: str, track: str, path: Path) -> tuple[str, int]:
        st = path.stat()
        key = f"{cid}/{track}"
        e = self.files.get(key)
        if e and e.get("size") == st.st_size and e.get("mtime_ns") == st.st_mtime_ns and isinstance(e.get("sha256"), str):
            return e["sha256"], st.st_size
        sha = file_sha256(path)
        self.files[key] = {"size": st.st_size, "mtime_ns": st.st_mtime_ns, "sha256": sha}
        self.changed = True
        return sha, st.st_size

    def save(self, keep_ids=None) -> None:
        if keep_ids is not None:
            before = len(self.files)
            self.files = {k: v for k, v in self.files.items() if k.rsplit("/", 1)[0] in keep_ids}
            self.changed |= len(self.files) != before
        if not self.changed:
            return
        f = cache_file()
        with jsonfile.locked(f):
            jsonfile.write_atomic(f, jsonfile.with_schema({"files": dict(sorted(self.files.items()))}))
        self.changed = False


# --- upload and download ---

def server_audio(srv, cid: str) -> dict:
    """GET /api/calls/{id}/audio -> {"tracks": {track: info}, "pending": {(track, sha256): {idx: size}},
    "removed": the server's audio_removed_at or None}."""
    remote = _remote()
    _, j = remote._request(srv, "GET", _audio_path(cid))
    if not isinstance(j, dict):
        raise remote.RemoteError(1, t("remote_bad_reply", path="/api/calls/{id}/audio"))
    tracks = {x["track"]: x for x in j.get("tracks") or [] if isinstance(x, dict) and x.get("track") in TRACKS}
    pending = {}
    for p in j.get("pending") or []:
        if isinstance(p, dict) and p.get("track") in TRACKS and isinstance(p.get("chunks"), list):
            pending[(p["track"], p.get("sha256"))] = {c.get("idx"): c.get("size") for c in p["chunks"] if isinstance(c, dict)}
    removed = j.get("audio_removed_at")
    return {"tracks": tracks, "pending": pending, "removed": removed if isinstance(removed, str) and removed else None}


def _number(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v == v


def start_offsets(meta: dict) -> dict:
    """{track: seconds after the earlier track started} from call.json audio mic_start / system_start."""
    starts = {k: float(meta[f"{k}_start"]) for k in TRACKS if _number(meta.get(f"{k}_start"))}
    t0 = min(starts.values(), default=0.0)
    # The server takes 0 to MAX_START seconds; anything else is a broken call.json, sent without an offset.
    return {k: round(v - t0, 6) for k, v in starts.items() if v - t0 <= MAX_START}


def upload_track(srv, cid: str, track: str, path: Path, sha: str, size: int, staged: dict,
                 start: float | None = None) -> None:
    """Send the chunks the server has not staged yet, then commit (with the start offset when known).
    Reads one chunk at a time."""
    n = max(1, -(-size // CHUNK))
    with open(path, "rb") as f:
        for idx in range(n):
            want = min(CHUNK, size - idx * CHUNK)
            if staged.get(idx) == want:
                continue  # resumed: the server has this chunk of this version already
            f.seek(idx * CHUNK)
            data = f.read(CHUNK)
            _raw(srv, "PUT", _audio_path(cid, track, idx), data, {"X-Sozvon-Sha256": sha})
    body = {"size": size, "chunks": n, "sha256": sha, **({"start": start} if start is not None else {})}
    _remote()._request(srv, "POST", _audio_path(cid, track, "commit"), body)


def push_call_audio(srv, d: Path, hashes: Hashes | None = None) -> int:
    """Upload the tracks of one finished call whose sha256 differs from the server's. -> tracks sent.
    Nothing for a call whose audio a Mac removed (here or, per the server, anywhere).
    StorageFull propagates (the caller stops uploading audio)."""
    d = Path(d)
    call = calls.read_call(d)
    if call.get("audio_removed_at") or call.get("status", "done") != "done" or not (d / "transcript.txt").is_file():
        return 0
    files = local_tracks(d)
    if not files:
        return 0
    hashes = hashes or Hashes()
    cid = call["id"]
    mine = {track: hashes.of(cid, track, f) for track, f in files.items()}
    state = server_audio(srv, cid)
    if state["removed"]:
        return 0
    offsets = start_offsets(calls.audio_meta(d, call))
    sent = 0
    for track, (sha, size) in mine.items():
        if (state["tracks"].get(track) or {}).get("sha256") == sha:
            continue
        upload_track(srv, cid, track, files[track], sha, size, state["pending"].get((track, sha), {}),
                     offsets.get(track))
        sent += 1
    return sent


def download_track(srv, cid: str, d: Path, track: str, info: dict) -> bool:
    """Download one track into the call folder: a hidden temp file, checked (size, sha256), renamed into place."""
    target = Path(d) / f"{track}.m4a"
    if target.exists():
        return False
    tmp = Path(d) / f".download-{uuid.uuid4().hex}.m4a"
    h = hashlib.sha256()
    size = 0
    try:
        with open(tmp, "wb") as f:
            for idx in range(int(info.get("chunks") or 0)):
                _, data = _raw(srv, "GET", _audio_path(cid, track, idx))
                f.write(data)
                h.update(data)
                size += len(data)
        if size != info.get("size") or h.hexdigest() != info.get("sha256"):
            raise _remote().RemoteError(1, t("remote_bad_reply", path="/api/calls/{id}/audio"))
        if target.exists():
            return False
        os.rename(tmp, target)
        return True
    finally:
        tmp.unlink(missing_ok=True)


def drop_stale_downloads(d: Path, now: float | None = None) -> None:
    """Remove .download-*.m4a an interrupted download left (killed mid-way: the finally never ran)."""
    import time
    now = time.time() if now is None else now
    for f in Path(d).glob(".download-*.m4a"):
        try:
            if now - f.stat().st_mtime > STALE_DOWNLOAD:
                f.unlink()
        except OSError:
            pass


def pull_call_audio(srv, d: Path) -> int:
    """Restore the tracks of a call that has none here (downloaded from the server on a new Mac). -> tracks.

    Adds to call.json audio what is missing there: {track}_seconds, and {track}_start (the server's start offsets)
    when the call has no start times at all."""
    from . import audio
    d = Path(d)
    call = calls.read_call(d)
    if call.get("audio_removed_at") or local_tracks(d) or call.get("status", "done") != "done":
        return 0
    state = server_audio(srv, call["id"])
    if state["removed"]:
        return 0
    drop_stale_downloads(d)
    got = 0
    meta_add = {}
    for track, info in sorted(state["tracks"].items()):
        if download_track(srv, call["id"], d, track, info):
            got += 1
            if _number(info.get("start")) and info["start"] >= 0:
                meta_add[f"{track}_start"] = info["start"]
            try:
                meta_add[f"{track}_seconds"] = audio.duration(d / f"{track}.m4a")
            except Exception:  # noqa: BLE001  the duration is only for display
                pass
    if meta_add:
        meta = call.get("audio") if isinstance(call.get("audio"), dict) else {}
        has_starts = any(_number(meta.get(f"{k}_start")) for k in TRACKS)
        missing = {k: v for k, v in meta_add.items() if not _number(meta.get(k))
                   and not (k.endswith("_start") and has_starts)}  # never mix offsets with absolute times
        if missing:
            calls.update_call(d, audio={**meta, **missing})
    return got


def delete_call_audio(srv, cid: str) -> None:
    _raw(srv, "DELETE", _audio_path(cid), missing_ok=True)


def sync_audio(srv, root: Path, status, attempt, skip: set, enabled: bool) -> tuple[int, int, int]:
    """After the text: tracks up and down, and the server copy of audio the app removed. -> (sent, downloaded, deleted).

    A call the server marks removed (audio_removed_at) is left alone: nothing up, nothing down, and the tracks
    here stay. A call removed here and not marked yet gets the DELETE (it marks it, even with no audio there);
    deleted counts the calls whose audio was on the server.

    A failure for one call counts as failed (attempt) and the rest goes on; a 507 stops uploads for this sync
    with one STATUS line, downloads and text are not affected.
    """
    remote = _remote()
    theirs, _ = remote.remote_state(srv)  # fresh: includes the calls the text step just sent
    local = {c.id: c for c in calls.list_calls(root)}
    hashes = Hashes()
    sent = downloaded = deleted = 0
    full = False
    try:
        for cid, c in sorted(local.items()):
            r = theirs.get(cid)
            if r is None or cid in skip or cid in attempt.failed:
                continue
            if r.audio_removed_at:  # removed on some Mac: never synced again, the tracks here stay
                continue
            call = calls.read_call(c.path)
            if call.get("audio_removed_at"):
                # The app deleted it after N days: on the server too, as a mark no other Mac uploads past.
                ok, _ = attempt.run(cid, delete_call_audio, srv, cid)
                deleted += 1 if ok and r.audio else 0
                continue
            if not enabled:
                continue
            files = local_tracks(c.path)
            if files and not full:
                if all(r.audio.get(k) == hashes.of(cid, k, f)[0] for k, f in files.items()):
                    continue
                try:
                    ok, n = attempt.run(cid, push_call_audio, srv, c.path, hashes)
                except StorageFull:
                    full = True
                    status(t("remote_status_audio_full"))
                    continue
                sent += n or 0
            elif not files and r.audio:
                ok, n = attempt.run(cid, pull_call_audio, srv, c.path)
                downloaded += n or 0
    finally:
        hashes.save(keep_ids=set(local))
    if sent or downloaded or deleted:
        status(t("remote_status_audio", sent=sent, downloaded=downloaded, deleted=deleted))
    return sent, downloaded, deleted
