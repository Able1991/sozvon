"""Optional own server: copies of finished calls for Claude on the phone (text; audio and voice prints optional).

The server is the user's own (docs/SERVER.md). Configured by SOZVON_SERVER_URL and SOZVON_SERVER_PASSWORD
in .env. Protocol (schema 1):
  GET    {url}/api/health                    -> {"ok": true, "version": "...", "schema": 1}   (no auth)
  GET    {url}/api/calls                     -> {"calls": [{"id", "hash", "folder", "notes", "notes_deleted",
                                                 "project_title"}], "deleted": [{"id", "at"}]}
                                                 (deleted: server 0.3.0+, project_title: 0.3.2+)
  GET    {url}/api/calls/{id}                -> the stored payload with its notes (restoring a call)
  PUT    {url}/api/calls/{id}                <- {"schema", "id", "hash", "folder", "call", "transcript", "summary",
                                                 "notes", "notes_deleted", "project_title"?, "restore"?}
                                                 -> 204, notes merged;
                                                 410 for a deleted call unless "restore": true
  POST   {url}/api/calls/{id}/notes          <- {"notes", "notes_deleted"} -> 204, notes merged (410: deleted call)
  DELETE {url}/api/calls/{id}                -> 204, and a call tombstone
  DELETE {url}/api/calls/{id}/notes/{note}   -> 204, a tombstone (410: deleted call)
  GET    {url}/api/voices                    -> {"voices": [record | {"id", "deleted": true, "updated_at"}]} (0.4.0+)
  PUT    {url}/api/voices/{id}               <- a voice record -> 204 (410: deleted later than this record)
  DELETE {url}/api/voices/{id}               -> 204, and a voice tombstone
Ingest requests carry "Authorization: Bearer <password>". No retries inside: the next sync catches up.
The password never goes to logs or messages.
The "call" of a PUT holds only CALL_FIELDS (plus audio durations); its hash leaves out the folder name.

Sync never deletes a server call because it is missing here: only calls the user moved to the Trash
in Sozvon, listed in <data>/server-deleted.json by the app. A server call missing here and not in
that list is downloaded (a fresh install restores everything).

A call deleted on another Mac (a call tombstone on the server) is never uploaded back: sync moves the
local copy to the Trash (reversible). It comes back to the server only when the user restores it in
Sozvon (undo), which lists it in <data>/server-restore.json: sync then PUTs it with "restore": true.
"""
import hashlib
import json
import os
import re
import shutil
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from . import calls, config, jsonfile, notes, paths, platform_support
from .i18n import t

SCHEMA = 1
TIMEOUT = 10
LOCAL_HOSTS = {"localhost", "127.0.0.1"}


class RemoteError(Exception):
    """code: 2 not configured or bad input (address, password), 1 anything else (network, server)."""

    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class Gone(RemoteError):
    """410: the call was deleted on the server (another Mac); only a PUT with "restore": true brings it back."""


class Unreachable(RemoteError):
    """No answer at all (network down, timeout): several in a row stop the sync."""


@dataclass(frozen=True)
class Server:
    url: str
    password: str = ""

    def __repr__(self) -> str:  # never show the password
        return f"Server(url={self.url!r})"


def normalize_url(url: str) -> str:
    """https://host[/path] without a trailing slash; http only for localhost and 127.0.0.1 (tests)."""
    u = urllib.parse.urlsplit((url or "").strip())
    host = (u.hostname or "").lower()
    ok = u.scheme == "https" or (u.scheme == "http" and host in LOCAL_HOSTS)
    if not ok or not host or u.username or u.password or u.query or u.fragment:
        raise RemoteError(2, t("remote_bad_url", url=url))
    return urllib.parse.urlunsplit((u.scheme, u.netloc, u.path.rstrip("/"), "", ""))


def server(settings: config.Settings | None = None) -> Server | None:
    """The configured server, None if the address or password is empty. A bad address raises RemoteError."""
    s = settings or config.load()
    if not s.server_url or not s.server_password:
        return None
    return Server(normalize_url(s.server_url), s.server_password)


USER_AGENT = "Sozvon (+https://github.com/Able1991/sozvon)"


def _request(srv: Server, method: str, path: str, body: dict | None = None, auth: bool = True,
             missing_ok: bool = False, conflict_ok: bool = False):
    """-> (status, parsed JSON or None). missing_ok: 404, 405 and 410 come back as (status, None);
    conflict_ok: 409 comes back as (409, its parsed body or None)."""
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(srv.url + path, data=data, method=method)
    # Cloudflare answers the default "Python-urllib" agent with 403 (error 1010), before our Worker runs.
    req.add_header("User-Agent", USER_AGENT)
    if data is not None:
        req.add_header("Content-Type", "application/json; charset=utf-8")
    if auth:
        req.add_header("Authorization", f"Bearer {srv.password}")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise RemoteError(2, t("remote_auth")) from None
        if missing_ok and e.code == 410:
            return e.code, None
        if e.code == 410:
            raise Gone(1, t("remote_http", code=e.code, method=method, path=path)) from None
        if missing_ok and e.code in (404, 405):
            return e.code, None
        if conflict_ok and e.code == 409:
            try:
                return 409, json.loads(e.read() or b"null")
            except (ValueError, OSError):
                return 409, None
        raise RemoteError(1, t("remote_http", code=e.code, method=method, path=path)) from None
    except (urllib.error.URLError, OSError) as e:
        reason = getattr(e, "reason", e)
        raise Unreachable(1, t("remote_unreachable", err=reason)) from None
    if not raw:
        return status, None
    try:
        return status, json.loads(raw)
    except ValueError:
        raise RemoteError(1, t("remote_bad_reply", path=path)) from None


def _call_path(cid: str) -> str:
    return "/api/calls/" + urllib.parse.quote(cid, safe="")


def _version(v: str) -> tuple:
    """"0.3.3" -> (0, 3, 3); anything unparsable -> ()."""
    try:
        return tuple(int(p) for p in str(v).split("-")[0].split("."))
    except ValueError:
        return ()


def health(srv: Server) -> str:
    """Server version; RemoteError if it does not answer like ours."""
    _, j = _request(srv, "GET", "/api/health", auth=False)
    if not isinstance(j, dict) or j.get("ok") is not True:
        raise RemoteError(1, t("remote_bad_reply", path="/api/health"))
    if j.get("schema") != SCHEMA:
        raise RemoteError(1, t("remote_schema", schema=j.get("schema")))
    return str(j.get("version") or "")


@dataclass
class RemoteCall:
    """A call in GET /api/calls. notes is None for a server without notes (older than this protocol)."""
    hash: str
    folder: str = ""
    notes: set | None = None
    notes_deleted: set = field(default_factory=set)
    project_title: str | None = None  # None: the server does not keep titles (older than 0.3.2)
    audio: dict = field(default_factory=dict)  # track -> sha256 of the audio the server holds (0.4.0+)
    audio_removed_at: str | None = None  # a Mac removed the call's audio (0.4.0+): no Mac syncs it again


def _ids(v) -> set:
    return {i for i in v if isinstance(i, str)} if isinstance(v, list) else set()


def remote_state(srv: Server) -> tuple:
    """(id -> RemoteCall, id -> deleted_at of call tombstones). The tombstones are None for a server
    older than 0.3.0, which does not keep them."""
    _, j = _request(srv, "GET", "/api/calls")
    items = j.get("calls") if isinstance(j, dict) else None
    if not isinstance(items, list):
        raise RemoteError(1, t("remote_bad_reply", path="/api/calls"))
    out = {}
    for c in items:
        if isinstance(c, dict) and c.get("id"):
            out[str(c["id"])] = RemoteCall(hash=str(c.get("hash") or ""), folder=str(c.get("folder") or ""),
                                           notes=_ids(c["notes"]) if isinstance(c.get("notes"), list) else None,
                                           notes_deleted=_ids(c.get("notes_deleted")),
                                           project_title=c["project_title"] if isinstance(c.get("project_title"), str)
                                           else None,
                                           audio={k: v for k, v in c["audio"].items() if isinstance(v, str)}
                                           if isinstance(c.get("audio"), dict) else {},
                                           audio_removed_at=c["audio_removed_at"]
                                           if isinstance(c.get("audio_removed_at"), str) and c["audio_removed_at"]
                                           else None)
    gone = j.get("deleted")
    tombs = None
    if isinstance(gone, list):
        tombs = {str(g["id"]): str(g.get("at") or "") for g in gone if isinstance(g, dict) and g.get("id")}
    return out, tombs


def fetch(srv: Server, cid: str) -> dict | None:
    """The stored payload of one call (GET /api/calls/{id}); None if the server has no such call."""
    status, j = _request(srv, "GET", _call_path(cid), missing_ok=True)
    if status in (404, 405, 410):
        return None
    if not isinstance(j, dict) or j.get("id") != cid:
        raise RemoteError(1, t("remote_bad_reply", path="/api/calls/{id}"))
    return j


# The call.json fields that go to the server (and come back in a restored call): what the server shows and
# searches (topic, project slug, names and participants, duration) and what the app needs to show a restored call. Never
# terms, engine, info_pending, track offsets or anything a future app version adds.
CALL_FIELDS = ("schema", "id", "created_at", "status", "profile", "names", "participants", "topic", "languages",
               "summary")
AUDIO_FIELDS = ("mic_seconds", "system_seconds")


def is_demo(call: dict) -> bool:
    """A demo call (call.json "demo": true, added from Settings > Assistants): fictional, never leaves this Mac."""
    return call.get("demo") is True


def local_calls(root: Path) -> tuple[dict, set]:
    """-> (the calls here that sync looks at by id, ids of the demo calls it leaves out entirely)."""
    found = {c.id: c for c in calls.list_calls(root)}
    demo = {cid for cid, c in found.items() if is_demo(calls.read_call(c.path))}
    return {cid: c for cid, c in found.items() if cid not in demo}, demo


def call_fields(call: dict, audio: dict | None = None) -> dict:
    """The whitelisted part of a call.json; audio: the track durations (call.json or meta.json)."""
    out = {k: call[k] for k in CALL_FIELDS if k in call}
    meta = audio if audio is not None else call.get("audio")
    if isinstance(meta, dict):
        # 61.0 as 61: the server stores call JSON through JavaScript, which writes it so; a restored call
        # must hash the same as the original or the two Macs would resend it to each other forever.
        a = {k: int(v) if float(v).is_integer() else v for k in AUDIO_FIELDS
             if isinstance(v := meta.get(k), (int, float)) and not isinstance(v, bool) and v == v}
        if a:
            out["audio"] = a
    return out


def content_hash(call: dict, transcript: str, summary: str | None) -> str:
    """sha256 over the canonical JSON of what is sent: the server compares it, the app does not resend.

    Notes are left out: they are diffed by id, so a note alone never resends the whole call. The folder
    name is left out too: it is sent, but a rename (or a name another Mac spells differently) never
    resends the call. call: the whitelisted fields (call_fields).
    """
    canon = json.dumps({"call": call_fields(call), "transcript": transcript, "summary": summary},
                       sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


def project_title(call: dict) -> str:
    """Title of the call's project on this Mac ("" if none): the server shows it instead of the slug."""
    from . import profiles
    slug = str(call.get("profile") or "")
    return str(profiles.load(slug).get("title") or "").strip() if slug else ""


def payload(d: Path) -> dict | None:
    """What goes to the server for a call folder; None if the call is not done or has no transcript.

    No audio here: tracks travel separately (remote_audio). Only the whitelisted call.json fields (CALL_FIELDS), transcript.txt and summary.md.
    Notes travel as their own fields (the newest MAX_NOTES), the project title (when this Mac knows one)
    as project_title. The title and the folder name are left out of the hash: a Mac without the project
    would otherwise resend the call on every sync, against a Mac that has it.
    """
    d = Path(d)
    raw = calls.read_call(d)
    if is_demo(raw):
        return None
    call = call_fields(raw, calls.audio_meta(d, raw))
    transcript = d / "transcript.txt"
    # Calls transcribed before call.json had a status (contract 0) count as done when they have a transcript.
    if call.get("status", "done") != "done" or not transcript.is_file():
        return None
    text = transcript.read_text(encoding="utf-8", errors="replace")
    summary_file = d / "summary.md"
    summary = summary_file.read_text(encoding="utf-8", errors="replace") if summary_file.is_file() else None
    return {"schema": SCHEMA, "id": call["id"], "hash": content_hash(call, text, summary),
            "folder": d.name, "call": call, "transcript": text, "summary": summary,
            "notes": notes.newest(notes.notes_of(raw)), "notes_deleted": notes.deleted_of(raw),
            **({"project_title": title} if (title := project_title(call)) else {})}


def _stale(r: "RemoteCall | None", body: dict, sent_titles: dict) -> bool:
    """The server lacks this call, holds other content, or this Mac's project title changed since it last
    sent one (sent_titles: id -> title, server-titles.json).

    Never resent only because the server shows another title: two Macs with different titles for the same
    project would otherwise overwrite each other on every sync. The first time (nothing recorded yet) a
    title that differs from the server's is sent once.
    """
    if r is None or r.hash != body["hash"]:
        return True
    title = body.get("project_title", "")
    if not title or r.project_title is None:
        return False
    last = sent_titles.get(body["id"])
    if last is None:
        if r.project_title == title:
            sent_titles[body["id"]] = title  # in step already: remember it
            return False
        return True
    return last != title


def push(d: Path, srv: Server | None = None) -> bool:
    """Send one call. -> False if there is nothing to send (not done, no server).
    Gone if the call was deleted on another Mac (it stays here only)."""
    srv = srv or server()
    body = payload(d)
    if srv is None or body is None:
        return False
    _request(srv, "PUT", _call_path(body["id"]), body)
    return True


def _post_notes(srv: Server, cid: str, items: list, deleted: list) -> bool:
    """POST /api/calls/{id}/notes. -> False if the server has no such call or no notes endpoint."""
    status, _ = _request(srv, "POST", _call_path(cid) + "/notes", {"notes": items, "notes_deleted": deleted},
                         missing_ok=True)
    return status not in (404, 405, 410)


def push_notes(d: Path, srv: Server | None = None) -> bool:
    """Send the notes of one call right away (after add_note). -> False if not sent; sync catches up."""
    srv = srv or server()
    if srv is None:
        return False
    call = calls.read_call(d)
    if is_demo(call):
        return False
    return _post_notes(srv, call["id"], notes.newest(notes.notes_of(call)), notes.deleted_of(call))


def delete(cid: str, srv: Server | None = None) -> bool:
    srv = srv or server()
    if srv is None:
        return False
    _request(srv, "DELETE", _call_path(cid))
    return True


# --- calls the user deleted in Sozvon: <data>/server-deleted.json, written by the app ---

def deleted_file() -> Path:
    return paths.data_dir() / "server-deleted.json"


def _id_list(data: dict) -> list:
    """The entries of {"schema": 1, "calls": [{"id": ..., ...}]} that have an id."""
    items = data.get("calls") if isinstance(data.get("calls"), list) else []
    return [c for c in items if isinstance(c, dict) and isinstance(c.get("id"), str) and c["id"]]


def _read_list(f: Path) -> list:
    return _id_list(jsonfile.read(f, default={}) or {})


def _change_list(f: Path, change) -> None:
    """Edit such a list under its flock: change(entries) -> the new entries (written only if they differ)."""
    with jsonfile.locked(f):
        data = jsonfile.read(f, default={}) or {}
        items = _id_list(data)
        new = change(list(items))
        if new != items or not f.exists():
            jsonfile.write_atomic(f, jsonfile.with_schema({**data, "calls": new}))


def deleted_calls(f: Path | None = None) -> list:
    """Ids of calls the user moved to the Trash in Sozvon that sync has not deleted on the server yet."""
    return list(dict.fromkeys(c["id"] for c in _read_list(f or deleted_file())))


def forget_deleted(ids, f: Path | None = None) -> None:
    """Drop ids from server-deleted.json (deleted on the server, or the call is back), under its flock."""
    f = f or deleted_file()
    drop = set(ids)
    if drop and f.exists():
        _change_list(f, lambda items: [c for c in items if c["id"] not in drop])


# --- calls the user put back in Sozvon (undo of "Move to Trash"): <data>/server-restore.json, by the app ---

def restore_file() -> Path:
    return paths.data_dir() / "server-restore.json"


def restore_calls(f: Path | None = None) -> list:
    """Ids the user restored in Sozvon: sync PUTs them with "restore": true, even over a tombstone."""
    return list(dict.fromkeys(c["id"] for c in _read_list(f or restore_file())))


def forget_restored(ids, f: Path | None = None) -> None:
    f = f or restore_file()
    drop = set(ids)
    if drop and f.exists():
        _change_list(f, lambda items: [c for c in items if c["id"] not in drop])


# --- calls this Mac removed because of a server tombstone: <data>/server-trashed.json, engine only ---
# Deleted here by the user (step 1) or moved to the Trash by sync (a tombstone from another Mac). If such a
# folder shows up again, the user put it back from the Finder Trash: it stays here only, logged once.

def trashed_file() -> Path:
    return paths.data_dir() / "server-trashed.json"


def _trashed(f: Path | None = None) -> dict:
    return {c["id"]: c for c in _read_list(f or trashed_file())}


def _remember_trashed(entries: dict, f: Path | None = None) -> None:
    """Replace server-trashed.json with these entries (id -> {"id", "at", "kept"?})."""
    f = f or trashed_file()
    if entries or f.exists():
        _change_list(f, lambda items: sorted(entries.values(), key=lambda c: c["id"]))


# --- the project title this Mac last sent per call: <data>/server-titles.json, engine only ---

def titles_file() -> Path:
    return paths.data_dir() / "server-titles.json"


def _sent_titles(f: Path | None = None) -> dict:
    data = jsonfile.read(f or titles_file(), default={}) or {}
    titles = data.get("titles") if isinstance(data.get("titles"), dict) else {}
    return {k: v for k, v in titles.items() if isinstance(k, str) and isinstance(v, str)}


def _save_titles(titles: dict, f: Path | None = None) -> None:
    f = f or titles_file()
    with jsonfile.locked(f):
        data = jsonfile.read(f, default={}) or {}
        if data.get("titles") != titles or not f.exists():
            jsonfile.write_atomic(f, jsonfile.with_schema({**data, "titles": dict(sorted(titles.items()))}))


move_to_trash = platform_support.move_to_trash  # re-exported: callers and tests use remote.move_to_trash


BUSY = {"recorded", "processing"}


def _busy(d: Path) -> bool:
    """Being recorded (no call.json, or one without a status yet) or waiting for / in transcription:
    never moved to the Trash. A call.json without a status counts as done only for an old call that
    has its transcript (contract 0)."""
    if not calls.call_file(d).is_file():
        return True
    try:
        call = jsonfile.read(calls.call_file(d), default=None, strict=True)
    except Exception:  # noqa: BLE001  a broken call.json: leave the folder alone
        return True
    if not isinstance(call, dict):
        return True
    status = call.get("status")
    if not isinstance(status, str) or not status:
        return not (d / "transcript.txt").is_file()
    return status in BUSY


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# --- restoring a call from the server ---

FULL_ID_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}(?:-\d+)?$")


DROP_CATEGORIES = {"Cc", "Cs", "Zl", "Zp"}  # control characters, lone surrogates, line and paragraph separators


def safe_folder(name, cid: str) -> str:
    """A folder name from the server that is safe to create in the calls folder; else the id itself.

    No path separators, colons, control characters or line separators, no leading dots, at most
    255 bytes, and it must start with the id (followed by the end or a space), as every Sozvon call
    folder does. Everything else is kept as is: no-break spaces, zero-width joiners in emoji.
    """
    if not isinstance(name, str):
        return cid
    name = "".join(ch for ch in name if unicodedata.category(ch) not in DROP_CATEGORIES)
    for ch in "/\\:":
        name = name.replace(ch, "-")
    name = name.strip(" \t").lstrip(".")
    if len(name.encode("utf-8")) > 255 or not (name == cid or name.startswith(cid + " ")):
        return cid
    if platform_support.SYSTEM == "win32":
        from . import platform_win32
        return platform_win32.call_folder_name(name, cid, paths.calls_dir())
    return name


def _transcript_md(cid: str, call: dict, transcript: str, summary: str | None, title: str = "") -> str:
    """transcript.md for a restored call (the app shows it), from transcript.txt lines.
    title: the project title from the server, for a project this Mac does not have."""
    from .pipeline import render
    project = project_title(call) or title or str(call.get("profile") or "")
    return render.render_md(cid, render.parse_txt(transcript), project, str(call.get("topic") or ""), summary)


def restore(root: Path, body: dict, taken: set | None = None) -> Path | None:
    """Create a call folder from the server's copy: call.json, transcript.txt/.md, summary.md, notes.

    No audio. -> the new folder, or None when the id is invalid or a folder with this id exists.
    The folder is assembled under a hidden temporary name and renamed into place, so the app, MCP
    and the search index never see half of it.
    """
    root = Path(root)
    cid = body.get("id")
    if not isinstance(cid, str) or not FULL_ID_RE.match(cid):
        return None
    if taken is None:
        taken = {c.id for c in calls.list_calls(root)}
    if cid in taken:
        return None
    transcript = body.get("transcript") if isinstance(body.get("transcript"), str) else ""
    summary = body.get("summary") if isinstance(body.get("summary"), str) else None
    # Only the whitelisted fields, even from a copy an older engine sent in full: never info_pending (the app
    # would ask what the call was about) or engine and terms from another Mac.
    call = call_fields(body["call"]) if isinstance(body.get("call"), dict) else {}
    call["id"] = cid
    call.setdefault("schema", calls.CALL_SCHEMA)
    if "status" in call and call["status"] != "done":
        call["status"] = "done"
    items = notes.notes_of({"notes": body.get("notes")})
    deleted = notes.deleted_of({"notes_deleted": body.get("notes_deleted")})
    if items:
        call["notes"] = items
    if deleted:
        call["notes_deleted"] = deleted
    target = root / safe_folder(body.get("folder"), cid)
    if target.resolve().parent != root.resolve() or target.exists():
        return None
    title = (body.get("project_title") if isinstance(body.get("project_title"), str) else "").strip()[:200]
    # A project this Mac doesn't have (projects are per Mac): keep its title for the Calls window's list and
    # project filter. Local only, never sent back (not in CALL_FIELDS).
    if title and call.get("profile") and not project_title(call):
        call["project_title"] = title
    tmp = root / f".restore-{uuid.uuid4().hex}"
    tmp.mkdir()
    try:
        jsonfile.write_atomic(tmp / "call.json", call)
        (tmp / "transcript.txt").write_text(transcript, encoding="utf-8")
        if summary is not None:
            (tmp / "summary.md").write_text(summary, encoding="utf-8")
        (tmp / "transcript.md").write_text(_transcript_md(cid, call, transcript, summary, title),
                                           encoding="utf-8")
        if target.exists():  # appeared meanwhile: never replace a folder
            raise FileExistsError(target)
        platform_support.rename_file(tmp, target)
    except FileExistsError:
        shutil.rmtree(tmp, ignore_errors=True)
        return None
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return target


# --- full sync ---

@dataclass
class SyncResult:
    sent: int = 0
    deleted: int = 0
    downloaded: int = 0
    trashed: int = 0
    failed: int = 0  # calls a request failed for (413, 5xx, timeout...): retried on the next sync

    def __iter__(self):  # (sent, deleted, downloaded, trashed, failed)
        return iter((self.sent, self.deleted, self.downloaded, self.trashed, self.failed))


MAX_UNREACHABLE = 3  # calls in a row with no answer at all: the server is down, stop instead of waiting for each


class _Attempts:
    """Runs one call's requests: a failure there counts and is a STATUS line, and the sync goes on with
    the other calls. A wrong password (code 2) or MAX_UNREACHABLE calls in a row without an answer stop it.
    Gone (410, deleted on another Mac a moment ago) is not a failure: the next sync handles the tombstone."""

    def __init__(self, result: SyncResult, status):
        self.result, self.status, self.unreachable = result, status, 0
        self.failed: set = set()  # ids that failed in this sync: not tried again until the next one

    def run(self, cid: str, fn, *args, **kwargs):
        """-> (ok, fn's value)."""
        try:
            value = fn(*args, **kwargs)
        except Gone:
            self.unreachable = 0
            return False, None
        except RemoteError as e:
            if e.code == 2:
                raise
            self.result.failed += 1
            self.failed.add(cid)
            self.status(t("remote_status_failed", id=cid, err=e.message))
            self.unreachable = self.unreachable + 1 if isinstance(e, Unreachable) else 0
            if self.unreachable >= MAX_UNREACHABLE:
                raise
            return False, None
        self.unreachable = 0
        return True, value


def sync(srv: Server | None = None, root: Path | None = None, status=lambda text: None,
         trash=None) -> SyncResult:
    """Make the server and the calls folder agree. -> SyncResult(sent, deleted, downloaded, trashed, failed).

    1. Calls the user deleted in Sozvon (server-deleted.json): deleted on the server (which keeps a
       call tombstone), then dropped from the list. Nothing else is ever deleted on the server.
    2. Calls the user restored in Sozvon (server-restore.json): sent with "restore": true.
    3. Calls deleted on another Mac (server 0.3.0+ tombstones): the copy here goes to the Trash
       (trash(path), move_to_trash by default), unless it is being recorded or transcribed (next sync).
       One this Mac already removed and the user put back from the Finder Trash stays here only.
       A tombstoned call is never uploaded.
    4. Server calls with no folder here and not deleted by the user: downloaded (no audio).
    5. Notes: the ones the server has and this Mac lacks come down, tombstones apply both ways,
       local notes the server lacks go up.
    6. Done calls the server lacks, holds with another hash, or whose project title changed here since
       this Mac last sent it: sent.
    7. Audio (server 0.4.0+, remote_audio.sync_audio) and 8. voice prints (sync_voices): their counts are
       STATUS lines; a call whose audio failed counts in failed, like its text.
    A request that fails for one call (413, 5xx, a timeout) is counted in failed and the rest goes on.
    """
    trash = trash or move_to_trash
    srv = srv or server()
    if srv is None:
        raise RemoteError(2, t("remote_not_configured"))
    root = Path(root or paths.calls_dir())
    if not root.is_dir():  # an unmounted or moved folder: do nothing at all
        raise RemoteError(2, t("err_no_dir", path=root))
    status(t("remote_status_check"))
    # 0.3.3+ keeps the newest MAX_NOTES notes of a call; older servers ignore notes over the limit.
    version = _version(health(srv))
    evicts = version >= (0, 3, 3)
    # Servers older than 0.3.2 drop project_title: nothing counts as sent there, so the title goes
    # out once the server is updated.
    keeps_titles = version >= (0, 3, 2)
    theirs, tombs = remote_state(srv)
    result = SyncResult()
    attempt = _Attempts(result, status)
    local, demo = local_calls(root)  # demo calls are fictional: not sent, not trashed, not overwritten
    sent_titles = _sent_titles()
    try:
        _sync(srv, root, status, trash, theirs, tombs, local, result, attempt, evicts, sent_titles, demo)
    finally:
        _save_titles({k: v for k, v in sent_titles.items() if k in local} if keeps_titles else {})
    from . import remote_audio, remote_voices
    if version >= remote_voices.VOICES_VERSION:
        settings = config.load()
        dead = set(tombs or {})
        remote_audio.sync_audio(srv, root, status, attempt, dead, enabled=settings.sync_audio)
        remote_voices.sync_voices(srv, status, enabled=settings.sync_voices)
    return result


def _sent(sent_titles: dict, body: dict) -> None:
    """After a successful PUT: the title this Mac sent (server-titles.json)."""
    if body.get("project_title"):
        sent_titles[body["id"]] = body["project_title"]


def _sync(srv, root, status, trash, theirs, tombs, local, result, attempt, evicts, sent_titles, demo=frozenset()) -> None:
    # 1. deletions made in Sozvon
    done, pending = [], set()
    for cid in deleted_calls():
        c = local.get(cid)
        if c is not None and calls.call_file(c.path).is_file():  # back (restored from the Trash): never delete
            done.append(cid)
            continue
        if cid in theirs:
            status(t("remote_status_delete", id=cid))
            ok, _ = attempt.run(cid, _request, srv, "DELETE", _call_path(cid))
            if not ok:  # stays in the list for the next sync, and is not downloaded meanwhile
                pending.add(cid)
                continue
            theirs.pop(cid)
            result.deleted += 1
            if tombs is not None:
                tombs.setdefault(cid, _now())  # the server keeps a tombstone now
        done.append(cid)
    forget_deleted(done)
    gone = set(done) | pending
    # What this Mac removed because of a tombstone (only a server 0.3.0+ has them): deleted here, trashed by sync.
    removed = _trashed() if tombs is not None else {}
    for cid in set(done) - set(local):
        if tombs is not None and cid in tombs:
            removed.setdefault(cid, {"id": cid, "at": _now()})

    # 2. calls the user put back in Sozvon: back on the server, over the tombstone
    restored, put_back = set(), []
    try:
        for cid in restore_calls():
            c = local.get(cid)
            if c is None:  # deleted again, or gone: nothing to restore
                put_back.append(cid)
                continue
            restored.add(cid)  # never trashed for its tombstone while the restore is pending
            body = payload(c.path)
            if body is None:  # not done yet: the next sync
                continue
            status(t("remote_status_restore", id=cid))
            ok, _ = attempt.run(cid, _request, srv, "PUT", _call_path(cid), {**body, "restore": True})
            if not ok:
                continue
            _sent(sent_titles, body)
            theirs[cid] = RemoteCall(hash=body["hash"], folder=body["folder"],
                                     notes={n["id"] for n in body["notes"]}, notes_deleted=set(body["notes_deleted"]),
                                     project_title=body.get("project_title", ""))
            if tombs is not None:
                tombs.pop(cid, None)
            removed.pop(cid, None)
            put_back.append(cid)
            result.sent += 1
    finally:  # what went through is consumed even if the sync stops later
        forget_restored(put_back)

    # 3. calls deleted on another Mac: to the Trash here, never uploaded back
    dead = set()
    if tombs is not None:
        dead = set(tombs) - restored

        def remember():
            _remember_trashed({cid: e for cid, e in removed.items() if cid in tombs})  # tombstone gone: forget
        for cid in sorted(dead & set(local)):
            c = local[cid]
            if cid in removed:  # put back from the Finder Trash after this Mac removed it
                if not removed[cid].get("kept"):
                    status(t("remote_status_kept_local", id=cid))
                    removed[cid] = {**removed[cid], "kept": True}
                continue
            if _busy(c.path):
                continue  # being recorded or transcribed: the next sync
            status(t("remote_status_trash", id=cid))
            try:
                trash(c.path)
            except OSError as e:
                status(t("remote_trash_failed", id=cid, err=e))
                continue
            removed[cid] = {"id": cid, "at": _now()}
            del local[cid]
            result.trashed += 1
            remember()  # right away: a sync that stops later must still know this Mac removed it
        remember()

    # 4. downloads: a fresh install, or calls recorded on another Mac
    missing = sorted(cid for cid, r in theirs.items()
                     if cid not in local and cid not in demo and cid not in gone and r.notes is not None and FULL_ID_RE.match(cid))
    for i, cid in enumerate(missing, 1):
        status(t("remote_status_download", i=i, n=len(missing), id=cid))
        ok, body = attempt.run(cid, fetch, srv, cid)
        if ok and body is not None and restore(root, body, taken=set(local)) is not None:
            result.downloaded += 1

    # 5, 6. notes and uploads of the calls here
    mine = []
    for c in local.values():
        if c.id in dead or c.id in attempt.failed:
            continue
        r = theirs.get(c.id)
        if r is not None and r.notes is not None:
            ok, _ = attempt.run(c.id, _pull_notes, srv, c, r, status)
            if not ok:
                continue
        body = payload(c.path)
        if body and _stale(r, body, sent_titles):
            mine.append(body)
        elif body and r is not None and r.notes is not None:
            ups = [n for n in body["notes"] if n["id"] not in r.notes and n["id"] not in r.notes_deleted]
            dels = [i for i in body["notes_deleted"] if i not in r.notes_deleted]
            if ups and not evicts and len(r.notes) >= notes.MAX_NOTES:
                ups = []  # an older server with a full call ignores them: sending again and again is a no-op
            if ups or dels:
                status(t("remote_status_notes", id=c.id))
                ok, _ = attempt.run(c.id, _push_note_changes, srv, c.id, ups, dels)
                if ok:
                    result.sent += 1
    for i, body in enumerate(mine, 1):
        status(t("remote_status_send", i=i, n=len(mine), id=body["id"]))
        ok, _ = attempt.run(body["id"], _request, srv, "PUT", _call_path(body["id"]), body)
        if ok:
            _sent(sent_titles, body)
            result.sent += 1


def _push_note_changes(srv: Server, cid: str, ups: list, dels: list) -> None:
    for nid in dels:
        _request(srv, "DELETE", f"{_call_path(cid)}/notes/{urllib.parse.quote(nid, safe='')}")
    if ups:
        _post_notes(srv, cid, ups, [])


def _pull_notes(srv: Server, c, r: RemoteCall, status) -> None:
    """Server notes this Mac lacks and server tombstones, into call.json."""
    call = calls.read_call(c.path)
    have = {n["id"] for n in notes.notes_of(call)}
    deleted = set(notes.deleted_of(call))
    new = r.notes - have - deleted
    dead = r.notes_deleted - deleted
    if not new and not dead:
        return
    status(t("remote_status_notes", id=c.id))
    incoming = []
    if new:
        body = fetch(srv, c.id) or {}
        incoming = [n for n in (body.get("notes") or []) if isinstance(n, dict) and n.get("id") in new]
    try:
        notes.merge(c.path, incoming, dead)
    except jsonfile.JsonFileError:
        pass  # a broken call.json is the user's to fix; never overwritten


def push_after_transcription(d: Path, log) -> None:
    """Pipeline hook: a failure is only a warning, the transcription result does not change.
    Text only: the tracks go up with the next full sync (bin/sync_server.py, resumable, in the background),
    which the app starts after every transcription."""
    try:
        if push(d):
            log(t("remote_pushed"))
    except Gone:
        log(t("remote_push_gone"))
    except RemoteError as e:
        log(t("remote_push_failed", err=e.message))
    except Exception as e:  # noqa: BLE001  the server must never break a finished transcription
        log(t("remote_push_failed", err=f"{type(e).__name__}: {e}"))


def main() -> int:
    """bin/sync_server.py: full sync. STATUS: lines, last line
    RESULT: ok <sent> <deleted> <downloaded> <trashed> <failed> or RESULT: error <code> <message>.
    Exit code 0, or 1 when some calls failed (failed > 0; each has a STATUS line, the rest went through)."""
    def status(text):
        print(f"STATUS: {text}", flush=True)

    try:
        sent, deleted, downloaded, trashed, failed = sync(status=status)
    except RemoteError as e:
        print(f"RESULT: error {e.code} {' '.join(e.message.split())}", flush=True)
        return e.code
    except Exception as e:  # noqa: BLE001
        print(f"RESULT: error 1 {' '.join(f'{type(e).__name__}: {e}'.split())}", flush=True)
        return 1
    print(f"RESULT: ok {sent} {deleted} {downloaded} {trashed} {failed}", flush=True)
    return 1 if failed else 0
