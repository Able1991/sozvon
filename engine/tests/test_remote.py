"""Own server: a tiny local fake of the protocol (health, list, get, put with note merge, notes, delete)."""
import hashlib
import json
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from sozvon_engine import config, remote, remote_audio

PASSWORD = "s3cret-pass"


class Fake:
    """State of the fake server: calls by id, the requests it saw."""

    def __init__(self):
        self.calls = {}
        self.notes = {}  # call id -> {note id: note}
        self.tombs = {}  # call id -> set of deleted note ids
        self.requests = []
        self.fail_put = False
        self.fail_ids = {}  # call id -> HTTP status its PUT and GET answer with
        self.version = "test-1"
        self.schema = 1
        self.legacy = False  # a server from before notes: list has only id and hash, no GET of one call
        self.gone = {}  # call tombstones: id -> deleted at
        self.old = False  # a server older than 0.3.0: no call tombstones
        self.voices = {}  # voice id -> record, or {"id", "deleted": True, "updated_at"} (server 0.4.0+)
        self.audio = {}  # call id -> {track: {"size", "chunks", "sha256", "data": bytes}} (server 0.4.0+)
        self.staged = {}  # (call id, track) -> {"sha256", "chunks": {idx: bytes}}
        self.audio_limit = None  # bytes: a chunk past it answers 507
        self.fail_chunk = None  # (call id, track, idx) whose PUT answers 500 once
        self.audio_removed = {}  # call id -> when a Mac removed its audio (DELETE .../audio): uploads answer 410

    def merge(self, cid, items, deleted):
        tombs = self.tombs.setdefault(cid, set())
        tombs.update(deleted or [])
        have = self.notes.setdefault(cid, {})
        for nid in list(have):
            if nid in tombs:
                del have[nid]
        for n in items or []:
            if n["id"] not in tombs:
                have.setdefault(n["id"], n)

    def put(self, body):
        """A stored call as a real server holds it (tests seed the server with it)."""
        cid = body["id"]
        self.calls[cid] = {k: v for k, v in body.items() if k not in ("notes", "notes_deleted")}
        self.merge(cid, body.get("notes"), body.get("notes_deleted"))


@pytest.fixture
def fake(monkeypatch):
    state = Fake()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, code, body=None):
            data = b"" if body is None else json.dumps(body).encode()
            self.send_response(code)
            if data:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def handle_any(self, method):
            path = urllib.parse.urlsplit(self.path).path
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
            octet = self.headers.get("Content-Type") == "application/octet-stream"
            body = raw if octet else (json.loads(raw) if n else None)
            state.requests.append((method, path, self.headers.get("Authorization"), body))
            if path == "/api/health" and method == "GET":
                return self.reply(200, {"ok": True, "version": state.version, "schema": state.schema})
            if self.headers.get("Authorization") != f"Bearer {PASSWORD}":
                return self.reply(401, {"error": "unauthorized"})
            if path == "/api/calls" and method == "GET":
                if state.legacy:
                    return self.reply(200, {"calls": [{"id": k, "hash": v["hash"]} for k, v in state.calls.items()]})
                reply = {"calls": [
                    {"id": k, "hash": v["hash"], "folder": v.get("folder", k),
                     "notes": sorted(state.notes.get(k, {})), "notes_deleted": sorted(state.tombs.get(k, set())),
                     **({} if state.old else {"project_title": v.get("project_title", "")}),
                     **({"audio": {tr: a["sha256"] for tr, a in state.audio[k].items()}} if state.audio.get(k) else {}),
                     **({"audio_removed_at": state.audio_removed[k]} if k in state.audio_removed else {})}
                    for k, v in state.calls.items()]}
                if not state.old:
                    reply["deleted"] = [{"id": k, "at": at} for k, at in sorted(state.gone.items())]
                return self.reply(200, reply)
            if path == "/api/voices" and method == "GET":
                return self.reply(200, {"voices": [state.voices[k] for k in sorted(state.voices)]})
            if path.startswith("/api/voices/"):
                vid = path[len("/api/voices/"):]
                prev = state.voices.get(vid)
                if method == "DELETE":
                    state.voices[vid] = {"id": vid, "deleted": True, "updated_at": "2026-11-05T10:00:00.000Z"}
                    return self.reply(204)
                if method == "PUT":
                    if prev and prev.get("deleted") and prev["updated_at"].replace(".000Z", "Z") >= body["updated_at"]:
                        return self.reply(410, {"error": "deleted"})
                    if prev and not prev.get("deleted") and prev["updated_at"] > body["updated_at"]:
                        if prev["embedding"] != body["embedding"]:
                            return self.reply(409, {"error": "changed later", "voice": prev})
                        return self.reply(204)
                    state.voices[vid] = body
                    return self.reply(204)
                return self.reply(405)
            prefix = "/api/calls/"
            if path.startswith(prefix):
                parts = [urllib.parse.unquote(p) for p in path[len(prefix):].split("/")]
                cid = parts[0]
                if parts[1:2] == ["audio"]:
                    return self.audio(method, cid, parts[2:], body)
                if cid in state.fail_ids and method in ("PUT", "GET"):
                    return self.reply(state.fail_ids[cid], {"error": "too large"})
                if cid in state.gone and not state.old and method in ("PUT", "POST", "DELETE") and parts[1:]:
                    return self.reply(410, {"error": "deleted"})
                if len(parts) == 1 and method == "GET" and not state.legacy:
                    if cid not in state.calls:
                        return self.reply(404, {"error": "unknown call"})
                    return self.reply(200, {**state.calls[cid],
                                            "notes": sorted(state.notes.get(cid, {}).values(), key=lambda n: n["at"]),
                                            "notes_deleted": sorted(state.tombs.get(cid, set()))})
                if len(parts) == 1 and method == "PUT":
                    if state.fail_put:
                        return self.reply(500, {"error": "boom"})
                    if cid in state.gone and not state.old:
                        if body.get("restore") is not True:
                            return self.reply(410, {"error": "deleted"})
                        del state.gone[cid]
                    state.put(body)
                    return self.reply(204)
                if len(parts) == 1 and method == "DELETE":
                    state.calls.pop(cid, None)
                    state.notes.pop(cid, None)
                    state.tombs.pop(cid, None)
                    state.audio.pop(cid, None)
                    if not state.old:
                        state.gone[cid] = "2026-11-05T10:00:00Z"
                    return self.reply(204)
                if not state.legacy and parts[1:] == ["notes"] and method == "POST":
                    if cid not in state.calls:
                        return self.reply(404, {"error": "unknown call"})
                    state.merge(cid, body.get("notes"), body.get("notes_deleted"))
                    return self.reply(204)
                if not state.legacy and len(parts) == 3 and parts[1] == "notes" and method == "DELETE":
                    state.merge(cid, [], [parts[2]])
                    return self.reply(204)
                return self.reply(405)
            return self.reply(404)

        def raw(self, code, data: bytes):
            self.send_response(code)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def audio(self, method, cid, rest, body):
            if not rest:
                if method == "DELETE":
                    state.audio.pop(cid, None)
                    for key in [k for k in state.staged if k[0] == cid]:
                        del state.staged[key]
                    state.audio_removed.setdefault(cid, "2026-12-04T09:00:00.000Z")
                    return self.reply(204)
                tracks = [{"track": tr, **{k: v for k, v in a.items() if k != "data"}, "updated_at": "x"}
                          for tr, a in sorted(state.audio.get(cid, {}).items())]
                pending = [{"track": tr, "sha256": st["sha256"],
                            "chunks": [{"idx": i, "size": len(b)} for i, b in sorted(st["chunks"].items())]}
                           for (c, tr), st in sorted(state.staged.items()) if c == cid]
                return self.reply(200, {"tracks": tracks, "pending": pending,
                                        "audio_removed_at": state.audio_removed.get(cid)})
            track, what = rest
            if cid in state.audio_removed and method in ("PUT", "POST"):
                return self.reply(410, {"error": "audio removed"})
            if what == "commit":
                st = state.staged.get((cid, track))
                if not st or st["sha256"] != body["sha256"] or sorted(st["chunks"]) != list(range(body["chunks"])):
                    return self.reply(409, {"error": "missing chunks"})
                data = b"".join(st["chunks"][i] for i in range(body["chunks"]))
                state.audio.setdefault(cid, {})[track] = {"size": len(data), "chunks": body["chunks"],
                                                          "sha256": body["sha256"], "data": data,
                                                          "start": body.get("start")}
                del state.staged[(cid, track)]
                return self.reply(204)
            idx = int(what)
            if method == "GET":
                a = state.audio.get(cid, {}).get(track)
                if not a or idx >= a["chunks"]:
                    return self.reply(404, {"error": "no such chunk"})
                return self.raw(200, a["data"][idx * remote_audio.CHUNK:(idx + 1) * remote_audio.CHUNK])
            if state.fail_chunk == (cid, track, idx):
                state.fail_chunk = None
                return self.reply(500, {"error": "boom"})
            if cid not in state.calls:
                return self.reply(404, {"error": "unknown call"})
            used = sum(a["size"] for t in state.audio.values() for a in t.values()) + sum(
                len(b) for st in state.staged.values() for b in st["chunks"].values())
            if state.audio_limit is not None and used + len(body) > state.audio_limit:
                return self.reply(507, {"error": "full"})
            sha = self.headers.get("X-Sozvon-Sha256")
            st = state.staged.get((cid, track))
            if not st or st["sha256"] != sha:
                st = state.staged[(cid, track)] = {"sha256": sha, "chunks": {}}
            st["chunks"][idx] = body
            return self.reply(204)

        def do_GET(self):
            self.handle_any("GET")

        def do_PUT(self):
            self.handle_any("PUT")

        def do_DELETE(self):
            self.handle_any("DELETE")

        def do_POST(self):
            self.handle_any("POST")

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    state.url = f"http://127.0.0.1:{httpd.server_address[1]}"
    monkeypatch.setenv("SOZVON_SERVER_URL", state.url + "/")
    monkeypatch.setenv("SOZVON_SERVER_PASSWORD", PASSWORD)
    yield state
    httpd.shutdown()
    httpd.server_close()


def make_call(root: Path, name: str, cid: str, status="done", transcript="[00:00] Я: Привет.\n", summary=None,
              notes=None) -> Path:
    d = root / name
    d.mkdir(parents=True)
    call = {"schema": 1, "id": cid, "status": status, "topic": "запуск"}
    if notes is not None:
        call["notes"] = notes
    (d / "call.json").write_text(json.dumps(call, ensure_ascii=False))
    (d / "mic.m4a").write_bytes(b"audio")
    if transcript is not None:
        (d / "transcript.txt").write_text(transcript, encoding="utf-8")
    if summary is not None:
        (d / "summary.md").write_text(summary, encoding="utf-8")
    return d


@pytest.fixture
def root(tmp_path):
    r = tmp_path / "Calls"
    r.mkdir()
    return r


def test_url_rule():
    assert remote.normalize_url("https://x.workers.dev/") == "https://x.workers.dev"
    assert remote.normalize_url("http://localhost:8787") == "http://localhost:8787"
    assert remote.normalize_url(" http://127.0.0.1:1/ ") == "http://127.0.0.1:1"
    for bad in ("http://x.workers.dev", "ftp://x", "x.workers.dev", "", "https://user:pw@x.dev", "https://x.dev/?a=1"):
        with pytest.raises(remote.RemoteError) as e:
            remote.normalize_url(bad)
        assert e.value.code == 2


def test_settings_keys(tmp_path):
    env = tmp_path / ".env"
    env.write_text('SOZVON_SERVER_URL="https://a.workers.dev"\nSOZVON_SERVER_PASSWORD="pw"\n')
    s = config.load(env, environ={})
    assert (s.server_url, s.server_password) == ("https://a.workers.dev", "pw")
    assert remote.server(s) == remote.Server("https://a.workers.dev", "pw")
    assert remote.server(config.load(tmp_path / "none", environ={})) is None
    assert "pw" not in repr(remote.server(s)), "the password never shows up in logs"


def test_payload_and_hash(root):
    d = make_call(root, "2026-11-04 15-01 · Acme", "2026-11-04 15-01", summary="## Итоги\n")
    body = remote.payload(d)
    assert set(body) == {"schema", "id", "hash", "folder", "call", "transcript", "summary", "notes", "notes_deleted"}
    assert body["id"] == "2026-11-04 15-01" and body["folder"] == "2026-11-04 15-01 · Acme"
    canon = json.dumps({"call": body["call"], "transcript": body["transcript"],
                        "summary": "## Итоги\n"}, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    assert body["hash"] == hashlib.sha256(canon.encode()).hexdigest()
    assert "mic.m4a" not in json.dumps(body) and "audio" not in body, "audio is never sent"
    assert remote.payload(make_call(root, "b", "2026-11-04 16-00", summary=None))["summary"] is None
    assert remote.payload(make_call(root, "c", "2026-11-04 17-00", status="processing")) is None
    assert remote.payload(make_call(root, "e", "2026-11-04 18-00", transcript=None)) is None


def test_project_title_is_sent_outside_the_hash(root, profiles):
    d = make_call(root, "2026-11-04 15-01", "2026-11-04 15-01")
    call = read(d)
    (d / "call.json").write_text(json.dumps({**call, "profile": "acme"}))
    without = remote.payload(d)
    assert "project_title" not in without, "no title for a project this Mac does not have"
    (profiles / "acme.json").write_text(json.dumps({"title": "Acme (Ромашка)"}, ensure_ascii=False))
    body = remote.payload(d)
    assert body["project_title"] == "Acme (Ромашка)" and body["hash"] == without["hash"]


def test_sync_resends_a_call_whose_project_title_changed(fake, root, profiles):
    d = make_call(root, "2026-11-04 15-01", "2026-11-04 15-01")
    (d / "call.json").write_text(json.dumps({**read(d), "profile": "acme"}))
    assert remote.sync(root=root).sent == 1
    assert "project_title" not in fake.calls["2026-11-04 15-01"]
    assert remote.sync(root=root).sent == 0, "no title here: nothing to resend"
    (profiles / "acme.json").write_text(json.dumps({"title": "Acme Corp"}))
    assert remote.sync(root=root).sent == 1
    assert fake.calls["2026-11-04 15-01"]["project_title"] == "Acme Corp"
    assert remote.sync(root=root).sent == 0, "same title: not resent"
    (profiles / "acme.json").write_text(json.dumps({"title": "Acme Inc"}))
    fake.old = True  # a server without titles: never resent for a title
    assert remote.sync(root=root).sent == 0


def test_restore_uses_the_server_project_title(root):
    body = {**server_copy("2026-11-04 15-01"), "project_title": "Acme Corp"}
    d = remote.restore(root, body, taken=set())
    assert (d / "transcript.md").read_text().startswith("# Звонок 2026-11-04 15-01 · Acme Corp · запуск")
    assert read(d)["project_title"] == "Acme Corp", "kept for the app: this Mac has no such project"
    sent = remote.payload(d)
    assert sent["hash"] == body["hash"] and "project_title" not in sent["call"] and "project_title" not in sent, \
        "local only: the call is not resent and the title is not sent back"


def test_restore_keeps_no_title_for_a_project_this_mac_has(root, data):
    (data / "profiles").mkdir(exist_ok=True)
    (data / "profiles" / "acme.json").write_text(json.dumps({"title": "Acme Inc"}))
    d = remote.restore(root, {**server_copy("2026-11-04 15-01"), "project_title": "Acme Corp"}, taken=set())
    assert "project_title" not in read(d), "this Mac's own title wins"


def test_notes_do_not_change_the_hash(root):
    d = make_call(root, "2026-11-04 15-01", "2026-11-04 15-01")
    before = remote.payload(d)
    call = json.loads((d / "call.json").read_text())
    call["notes"] = [note("n1")]
    call["notes_deleted"] = ["n0"]
    (d / "call.json").write_text(json.dumps(call))
    after = remote.payload(d)
    assert after["hash"] == before["hash"], "a note alone never resends the whole call"
    assert "notes" not in after["call"] and after["notes"] == [note("n1")] and after["notes_deleted"] == ["n0"]


def note(nid, text="заметка", at="2026-11-04T12:00:00Z", source="claude"):
    return {"id": nid, "at": at, "text": text, "source": source}


def read(d: Path) -> dict:
    return json.loads((d / "call.json").read_text())


def server_copy(cid, folder=None, notes=(), deleted=(), summary="## Итоги\nок\n", call=None):
    """A call stored on the server, as this client would have sent it."""
    call = call or {"schema": 1, "id": cid, "status": "done", "topic": "запуск", "profile": "acme",
                    "names": ["Анна"], "audio": {"mic_seconds": 61.0}}
    transcript = "[00:01] Анна: Привет\n[01:02:03] Я: Пока\n"
    folder = folder or f"{cid} · Acme · запуск"
    return {"schema": 1, "id": cid, "hash": remote.content_hash(call, transcript, summary), "folder": folder,
            "call": call, "transcript": transcript, "summary": summary, "notes": list(notes),
            "notes_deleted": list(deleted)}


def tombstone(data, *ids):
    (data / "server-deleted.json").write_text(json.dumps(
        {"schema": 1, "calls": [{"id": i, "at": "2026-11-05T10:00:00Z"} for i in ids]}))


def test_sync_sends_changed_and_never_deletes_missing(fake, root):
    make_call(root, "2026-11-04 15-01 · Acme", "2026-11-04 15-01")
    make_call(root, "2026-11-04 15-01-2", "2026-11-04 15-01-2", summary="s")
    make_call(root, "2026-11-04 16-00", "2026-11-04 16-00", status="processing")
    fake.put(server_copy("2026-11-04 16-00"))  # being retranscribed: stays on the server
    fake.put(server_copy("2026-01-01 10-00"))  # missing here: downloaded, never deleted
    assert tuple(remote.sync(root=root)) == (2, 0, 1, 0, 0)
    assert set(fake.calls) == {"2026-11-04 15-01", "2026-11-04 15-01-2", "2026-11-04 16-00", "2026-01-01 10-00"}
    assert not [r for r in fake.requests if r[0] == "DELETE"]
    puts = [r for r in fake.requests if r[0] == "PUT"]
    assert {r[1] for r in puts} == {"/api/calls/2026-11-04%2015-01", "/api/calls/2026-11-04%2015-01-2"}
    assert all(r[2] == f"Bearer {PASSWORD}" for r in fake.requests if r[1] != "/api/health")
    assert all(r[2] is None for r in fake.requests if r[1] == "/api/health"), "health without auth"
    fake.requests.clear()
    assert tuple(remote.sync(root=root)) == (0, 0, 0, 0, 0), "unchanged calls are not resent, restored ones neither"
    assert [r[0] for r in fake.requests] == ["GET", "GET"]
    (root / "2026-11-04 15-01-2" / "summary.md").write_text("новое")
    assert tuple(remote.sync(root=root)) == (1, 0, 0, 0, 0)


def test_fresh_install_downloads_everything(fake, root, data, capsys):
    fake.put(server_copy("2026-11-04 15-01", notes=[note("n1", "позвонить")], deleted=["n0"]))
    fake.put(server_copy("2026-11-05 09-30-2", folder="2026-11-05 09-30-2", summary=None,
                         call={"id": "2026-11-05 09-30-2", "topic": "old call without status"}))
    assert remote.main() == 0
    assert capsys.readouterr().out.strip().splitlines()[-1] == "RESULT: ok 0 0 2 0 0"
    a = root / "2026-11-04 15-01 · Acme · запуск"
    assert sorted(p.name for p in a.iterdir()) == ["call.json", "summary.md", "transcript.md", "transcript.txt"]
    c = read(a)
    assert c["status"] == "done" and c["names"] == ["Анна"] and c["notes"] == [note("n1", "позвонить")]
    assert c["notes_deleted"] == ["n0"]
    assert (a / "transcript.txt").read_text() == "[00:01] Анна: Привет\n[01:02:03] Я: Пока\n"
    md = (a / "transcript.md").read_text()
    assert md.startswith("# Звонок 2026-11-04 15-01 · acme · запуск") and "**[01:02:03] Я:** Пока" in md
    assert "## Итоги" in md
    b = root / "2026-11-05 09-30-2"
    assert not (b / "summary.md").exists() and "status" not in read(b), "the stored call.json is kept as is"
    assert not list(root.glob(".restore-*")), "no temporary folders left"
    assert not [r for r in fake.requests if r[0] in ("PUT", "DELETE", "POST")], "nothing sent back"
    from sozvon_engine.mcp import tools
    assert "позвонить" in tools.get_call("2026-11-04 15-01")


def test_download_skips_existing_id_and_tombstoned(fake, root, data):
    make_call(root, "2026-11-04 15-01 renamed here", "2026-11-04 15-01")
    fake.put(server_copy("2026-11-04 15-01"))
    fake.put(server_copy("2026-11-04 16-00"))
    tombstone(data, "2026-11-04 16-00")
    result = remote.sync(root=root)
    assert result.downloaded == 0 and result.deleted == 1
    assert sorted(p.name for p in root.iterdir()) == ["2026-11-04 15-01 renamed here"]
    assert set(fake.calls) == {"2026-11-04 15-01"}
    assert remote.deleted_calls() == [], "consumed after the delete"


def test_restore_never_replaces_a_folder(root):
    body = server_copy("2026-11-04 15-01")
    (root / body["folder"]).mkdir()  # a stray empty folder without call.json and another id
    (root / body["folder"] / "keep.txt").write_text("x")
    assert remote.restore(root, body, taken=set()) is None
    assert (root / body["folder"] / "keep.txt").exists()
    assert remote.restore(root, {**body, "id": "../../etc"}) is None
    assert remote.restore(root, {**body, "id": "2026-11-04"}) is None


@pytest.mark.parametrize("folder, want", [
    ("2026-11-04 15-01 · Acme", "2026-11-04 15-01 · Acme"),
    ("2026-11-04 15-01", "2026-11-04 15-01"),
    ("../2026-11-04 15-01", "2026-11-04 15-01"),
    ("2026-11-04 15-01 · a/../../b", "2026-11-04 15-01 · a-..-..-b"),
    ("2026-11-04 15-01 · a\\b:c", "2026-11-04 15-01 · a-b-c"),
    ("2026-11-04 15-01 · line\nbreak\x00", "2026-11-04 15-01 · linebreak"),
    ("2026-11-04 15-012", "2026-11-04 15-01"),
    ("..", "2026-11-04 15-01"),
    ("", "2026-11-04 15-01"),
    (None, "2026-11-04 15-01"),
    ("2026-11-04 15-01 · " + "я" * 200, "2026-11-04 15-01"),
])
def test_folder_name_sanitizing(folder, want):
    assert remote.safe_folder(folder, "2026-11-04 15-01") == want


def test_path_traversal_folder_stays_inside(fake, root, tmp_path):
    fake.put(server_copy("2026-11-04 15-01", folder="../../evil"))
    assert remote.sync(root=root).downloaded == 1
    assert (root / "2026-11-04 15-01" / "call.json").exists()
    assert not (tmp_path / "evil").exists() and not (root.parent.parent / "evil").exists()


def test_tombstone_deletes_only_what_the_user_deleted(fake, root, data):
    make_call(root, "2026-11-04 15-01", "2026-11-04 15-01")
    fake.put(server_copy("2026-11-04 15-01"))
    fake.put(server_copy("2026-11-04 16-00"))
    fake.put(server_copy("2026-11-04 17-00"))
    tombstone(data, "2026-11-04 16-00", "2026-11-04 15-01", "2026-01-01 00-00")
    r = remote.sync(root=root)
    assert (r.deleted, r.downloaded) == (1, 1)
    assert set(fake.calls) == {"2026-11-04 15-01", "2026-11-04 17-00"}, \
        "15-01 is back in the folder (restored from the Trash): kept"
    assert [r[1] for r in fake.requests if r[0] == "DELETE"] == ["/api/calls/2026-11-04%2016-00"]
    assert remote.deleted_calls() == []


def test_tombstone_kept_when_delete_fails(fake, root, data, monkeypatch):
    fake.put(server_copy("2026-11-04 16-00"))
    tombstone(data, "2026-11-04 16-00")
    real = remote._request

    def failing(srv, method, path, *a, **kw):
        if method == "DELETE":
            raise remote.RemoteError(1, "boom")
        return real(srv, method, path, *a, **kw)

    monkeypatch.setattr(remote, "_request", failing)
    lines = []
    assert remote.sync(root=root, status=lines.append).failed == 1
    assert any("2026-11-04 16-00" in line and "boom" in line for line in lines)
    assert remote.deleted_calls() == ["2026-11-04 16-00"], "retried on the next sync"
    assert not list(root.iterdir()), "never downloaded while the user's delete is pending"


def test_empty_folder_never_deletes(fake, root):
    fake.put(server_copy("2026-11-04 15-01"))
    assert remote.sync(root=root).deleted == 0
    assert set(fake.calls) == {"2026-11-04 15-01"}


def test_notes_pulled_from_server(fake, root):
    d = make_call(root, "2026-11-04 15-01", "2026-11-04 15-01", notes=[note("mine", at="2026-11-04T13:00:00Z")])
    body = remote.payload(d)
    fake.put({**body, "notes": [note("mine", at="2026-11-04T13:00:00Z"), note("phone", "с телефона")]})
    fake.requests.clear()
    assert tuple(remote.sync(root=root)) == (0, 0, 0, 0, 0)
    assert [n["id"] for n in read(d)["notes"]] == ["phone", "mine"]
    assert not [r for r in fake.requests if r[0] in ("PUT", "POST")], "pulled notes are not sent back"
    fake.requests.clear()
    remote.sync(root=root)
    assert [r[0] for r in fake.requests] == ["GET", "GET"], "in step: nothing to do"


def test_notes_pushed_without_resending_the_call(fake, root):
    d = make_call(root, "2026-11-04 15-01", "2026-11-04 15-01")
    remote.sync(root=root)
    call = read(d)
    call["notes"] = [note("n1", "из приложения", source="app")]
    (d / "call.json").write_text(json.dumps(call, ensure_ascii=False))
    fake.requests.clear()
    assert remote.sync(root=root).sent == 1
    assert [r[0] for r in fake.requests if r[0] != "GET"] == ["POST"]
    assert list(fake.notes["2026-11-04 15-01"]) == ["n1"]


def test_put_merges_and_never_drops_server_notes(fake, root):
    d = make_call(root, "2026-11-04 15-01", "2026-11-04 15-01", notes=[note("local")])
    fake.put({**remote.payload(d), "hash": "old", "notes": [note("server-only")]})
    remote.sync(root=root)
    assert set(fake.notes["2026-11-04 15-01"]) == {"local", "server-only"}
    assert {n["id"] for n in read(d)["notes"]} == {"local", "server-only"}


def test_note_tombstones_both_ways(fake, root):
    d = make_call(root, "2026-11-04 15-01", "2026-11-04 15-01", notes=[note("a"), note("b"), note("c")])
    remote.sync(root=root)
    # deleted in the app here: a tombstone in call.json
    call = read(d)
    call["notes"] = [n for n in call["notes"] if n["id"] != "a"]
    call["notes_deleted"] = ["a"]
    (d / "call.json").write_text(json.dumps(call))
    # deleted on another Mac: a tombstone on the server
    fake.merge("2026-11-04 15-01", [], ["b"])
    fake.requests.clear()
    remote.sync(root=root)
    assert [r[1] for r in fake.requests if r[0] == "DELETE"] == ["/api/calls/2026-11-04%2015-01/notes/a"]
    assert set(fake.notes["2026-11-04 15-01"]) == {"c"}
    c = read(d)
    assert [n["id"] for n in c["notes"]] == ["c"] and set(c["notes_deleted"]) == {"a", "b"}
    # a stale copy can't resurrect a deleted note
    fake.put({**remote.payload(d), "notes": [note("a"), note("c")]})
    assert set(fake.notes["2026-11-04 15-01"]) == {"c"}


def test_legacy_server_without_notes(fake, root):
    fake.legacy = True
    make_call(root, "2026-11-04 15-01", "2026-11-04 15-01", notes=[note("n")])
    fake.put(server_copy("2026-11-04 16-00"))
    assert tuple(remote.sync(root=root)) == (1, 0, 0, 0, 0), "an old server: no downloads, no deletes"
    assert set(fake.calls) == {"2026-11-04 15-01", "2026-11-04 16-00"}


def test_push_notes(fake, root):
    d = make_call(root, "2026-11-04 15-01", "2026-11-04 15-01", notes=[note("n")])
    assert remote.push_notes(d) is False, "the server has no such call yet"
    remote.push(d)
    fake.notes.clear()
    assert remote.push_notes(d) is True and list(fake.notes["2026-11-04 15-01"]) == ["n"]


def test_forget_deleted(data):
    tombstone(data, "a", "b")
    remote.forget_deleted(["a", "zzz"])
    assert remote.deleted_calls() == ["b"]
    assert json.loads((data / "server-deleted.json").read_text())["schema"] == 1
    (data / "server-deleted.json").write_text("{broken")
    assert remote.deleted_calls() == []


def test_wrong_password_is_2(fake, root, monkeypatch):
    monkeypatch.setenv("SOZVON_SERVER_PASSWORD", "nope")
    with pytest.raises(remote.RemoteError) as e:
        remote.sync(root=root)
    assert e.value.code == 2 and "nope" not in e.value.message


def test_missing_calls_folder_does_nothing(fake, tmp_path, data):
    fake.put(server_copy("2026-11-04 15-01"))
    tombstone(data, "2026-11-04 15-01")
    with pytest.raises(remote.RemoteError) as e:
        remote.sync(root=tmp_path / "missing")
    assert e.value.code == 2 and set(fake.calls) == {"2026-11-04 15-01"}
    assert not (tmp_path / "missing").exists(), "an unmounted folder is not created by downloads"


def test_schema_mismatch(fake, root):
    fake.schema = 2
    with pytest.raises(remote.RemoteError) as e:
        remote.sync(root=root)
    assert e.value.code == 1


def test_push_and_delete(fake, root):
    d = make_call(root, "2026-11-04 15-01", "2026-11-04 15-01")
    assert remote.push(d) is True
    assert fake.calls["2026-11-04 15-01"]["transcript"] == "[00:00] Я: Привет.\n"
    assert fake.calls["2026-11-04 15-01"]["call"]["topic"] == "запуск"
    assert remote.delete("2026-11-04 15-01") is True and fake.calls == {}


def test_not_configured(root, monkeypatch, capsys):
    assert remote.push(make_call(root, "x", "2026-11-04 15-01")) is False
    assert remote.main() == 2
    assert capsys.readouterr().out.strip().splitlines()[-1].startswith("RESULT: error 2 сервер не настроен")


def test_main_output(fake, root, data, capsys):
    make_call(root, "2026-11-04 15-01", "2026-11-04 15-01")
    fake.put(server_copy("2026-11-04 16-00"))
    fake.put(server_copy("2026-11-04 17-00"))
    fake.calls["not an id"] = {"hash": "x"}  # never downloaded: not a call id
    tombstone(data, "2026-11-04 17-00")
    assert remote.main() == 0
    lines = capsys.readouterr().out.strip().splitlines()
    assert lines[-1] == "RESULT: ok 1 1 1 0 0"
    assert "not an id" in fake.calls
    assert all(line.startswith("STATUS: ") for line in lines[:-1]) and PASSWORD not in "\n".join(lines)


def test_unreachable_is_1(monkeypatch, root, capsys):
    monkeypatch.setenv("SOZVON_SERVER_URL", "http://127.0.0.1:9")
    monkeypatch.setenv("SOZVON_SERVER_PASSWORD", PASSWORD)
    assert remote.main() == 1
    out = capsys.readouterr().out
    assert out.strip().splitlines()[-1].startswith("RESULT: error 1 сервер недоступен") and PASSWORD not in out


def test_pipeline_push_failure_keeps_result(fake, root, tmp_path, capsys, monkeypatch):
    """A finished transcription is pushed; a server failure is only a warning."""
    from sozvon_engine.pipeline import run

    def process(spec, settings, data):
        (spec.dir / "transcript.txt").write_text("[00:00] Я: Привет.\n", encoding="utf-8")
        return []  # the participants

    monkeypatch.setattr(run, "process", process)
    d = make_call(root, "2026-11-04 15-01", "2026-11-04 15-01", status="recorded", transcript=None)
    assert run.main([str(d)]) == 0
    assert capsys.readouterr().out.strip().splitlines()[-1] == "RESULT: ok"
    assert "2026-11-04 15-01" in fake.calls, "pushed after transcription"

    fake.calls.clear()
    fake.fail_put = True
    assert run.main([str(d)]) == 0
    cap = capsys.readouterr()
    assert cap.out.strip().splitlines()[-1] == "RESULT: ok"
    assert "не отправлен на свой сервер" in cap.err


def test_pipeline_bad_url_keeps_result(root, capsys, monkeypatch):
    from sozvon_engine.pipeline import run
    monkeypatch.setenv("SOZVON_SERVER_URL", "http://example.com")
    monkeypatch.setenv("SOZVON_SERVER_PASSWORD", PASSWORD)
    monkeypatch.setattr(run, "process", lambda spec, settings, data: [])
    d = make_call(root, "2026-11-04 15-01", "2026-11-04 15-01", status="recorded")
    assert run.main([str(d)]) == 0
    assert capsys.readouterr().out.strip().splitlines()[-1] == "RESULT: ok"


def test_legacy_call_without_status_is_sent(tmp_path):
    from sozvon_engine import remote
    d = tmp_path / "2026-11-01 10-00 · Acme"
    d.mkdir()
    (d / "call.json").write_text('{"profile": "acme", "names": ["Anna"]}', encoding="utf-8")
    (d / "transcript.txt").write_text("[00:01] Anna: hello\n", encoding="utf-8")
    body = remote.payload(d)
    assert body and body["id"] == "2026-11-01 10-00"
    (d / "call.json").write_text('{"status": "processing"}', encoding="utf-8")
    assert remote.payload(d) is None


def test_requests_send_a_sozvon_user_agent(monkeypatch):
    from sozvon_engine import remote
    seen = {}

    class R:
        status = 200
        def read(self): return b'{"ok": true, "schema": 1, "version": "x"}'
        def __enter__(self): return self
        def __exit__(self, *a): return False

    def fake(req, timeout):
        seen["ua"] = req.get_header("User-agent")
        return R()
    monkeypatch.setattr(remote.urllib.request, "urlopen", fake)
    remote.health(remote.Server("https://example.test", "pw"))
    assert seen["ua"].startswith("Sozvon")


# --- calls deleted on another Mac: server call tombstones (server 0.3.0+) ---

CID = "2026-11-04 15-01"
REAL_MOVE_TO_TRASH = remote.move_to_trash  # conftest replaces it with one that fails the test


class FakeTrash:
    def __init__(self, d: Path):
        self.dir = d
        d.mkdir()
        self.moved = []

    def __call__(self, path):
        self.moved.append(Path(path).name)
        Path(path).rename(self.dir / Path(path).name)


@pytest.fixture
def two_macs(fake, tmp_path, data, monkeypatch):
    """Mac A and Mac B with the same call, both synced; each Mac has its own data folder."""
    a, b = tmp_path / "A", tmp_path / "B"
    data_b = tmp_path / "data-b"
    data_b.mkdir()
    for r in (a, b):
        make_call(r, f"{CID} · Acme", CID)
    assert remote.sync(root=a).sent == 1
    assert tuple(remote.sync(root=b)) == (0, 0, 0, 0, 0)

    def on(mac):  # switch the data folder to that Mac's
        monkeypatch.setenv("SOZVON_DATA_DIR", str(data if mac == "A" else data_b))
    return a, b, on


def delete_on_a(a, data):
    """Mac A: the user moves the call to the Trash in Sozvon, the app lists it, sync deletes it."""
    (a / f"{CID} · Acme").rename(a.parent / "a-trash")
    tombstone(data, CID)
    assert remote.sync(root=a).deleted == 1


def test_deleted_on_one_mac_goes_to_the_trash_on_another(fake, two_macs, data, tmp_path):
    a, b, on = two_macs
    delete_on_a(a, data)
    assert CID in fake.gone and CID not in fake.calls
    on("B")
    trash = FakeTrash(tmp_path / "Trash")
    fake.requests.clear()
    assert tuple(remote.sync(root=b, trash=trash)) == (0, 0, 0, 1, 0)
    assert trash.moved == [f"{CID} · Acme"] and not list(b.iterdir())
    assert (trash.dir / f"{CID} · Acme" / "mic.m4a").exists(), "the whole folder, audio too, reversible"
    assert not [r for r in fake.requests if r[0] in ("PUT", "POST", "DELETE")], "never uploaded back"
    assert CID not in fake.calls
    assert tuple(remote.sync(root=b, trash=trash)) == (0, 0, 0, 0, 0)


def test_put_back_from_the_finder_trash_stays_local_and_is_logged_once(fake, two_macs, data, tmp_path):
    a, b, on = two_macs
    delete_on_a(a, data)
    on("B")
    trash = FakeTrash(tmp_path / "Trash")
    remote.sync(root=b, trash=trash)
    (trash.dir / f"{CID} · Acme").rename(b / f"{CID} · Acme")  # Finder: Put Back
    lines = []
    fake.requests.clear()
    assert tuple(remote.sync(root=b, trash=trash, status=lines.append)) == (0, 0, 0, 0, 0)
    assert (b / f"{CID} · Acme").is_dir() and trash.moved == [f"{CID} · Acme"], "not trashed again"
    assert len([line for line in lines if CID in line and "только на этом Mac" in line]) == 1
    assert not [r for r in fake.requests if r[0] in ("PUT", "POST", "DELETE")] and CID not in fake.calls
    lines.clear()
    remote.sync(root=b, trash=trash, status=lines.append)
    assert not [line for line in lines if "только на этом Mac" in line], "logged once per id"
    # the same on Mac A, where the user deleted it: put back from the Finder Trash after the sync
    on("A")
    (a.parent / "a-trash").rename(a / f"{CID} · Acme")
    lines.clear()
    assert tuple(remote.sync(root=a, trash=trash, status=lines.append)) == (0, 0, 0, 0, 0)
    assert (a / f"{CID} · Acme").is_dir() and CID not in fake.calls
    assert [line for line in lines if "только на этом Mac" in line]


def test_restore_in_sozvon_brings_the_call_back(fake, two_macs, data, tmp_path):
    a, b, on = two_macs
    delete_on_a(a, data)
    on("B")
    trash = FakeTrash(tmp_path / "Trash")
    remote.sync(root=b, trash=trash)
    on("A")  # undo in the Calls window: the folder is back, the app lists it in server-restore.json
    (a.parent / "a-trash").rename(a / f"{CID} · Acme")
    (data / "server-restore.json").write_text(json.dumps({"schema": 1, "calls": [{"id": CID, "at": "x"}]}))
    fake.requests.clear()
    assert tuple(remote.sync(root=a, trash=trash)) == (1, 0, 0, 0, 0)
    puts = [r for r in fake.requests if r[0] == "PUT"]
    assert len(puts) == 1 and puts[0][3]["restore"] is True
    assert CID in fake.calls and CID not in fake.gone
    assert remote.restore_calls() == [], "consumed on success"
    assert json.loads((data / "server-restore.json").read_text())["schema"] == 1
    fake.requests.clear()
    assert tuple(remote.sync(root=a, trash=trash)) == (0, 0, 0, 0, 0)
    assert not [r for r in fake.requests if r[0] == "PUT"]
    on("B")  # B trashed its copy before: the call comes down again from the server
    assert tuple(remote.sync(root=b, trash=trash)) == (0, 0, 1, 0, 0)
    assert remote.trashed_file().exists() and remote._trashed() == {}, "tombstone gone: forgotten"


def test_restore_list_keeps_a_failed_put_and_drops_gone_calls(fake, root, data):
    d = make_call(root, CID, CID)
    remote.push(d)
    remote.delete(CID)
    (data / "server-restore.json").write_text(json.dumps(
        {"schema": 1, "calls": [{"id": "2026-01-01 10-00"}, {"id": CID}]}))
    fake.fail_put = True
    trash = FakeTrash(root.parent / "Trash")
    assert remote.sync(root=root, trash=trash).failed == 1
    assert not trash.moved, "a pending restore is never trashed for its tombstone"
    assert remote.restore_calls() == [CID], "retried on the next sync; the missing call is dropped"
    assert d.is_dir()
    fake.fail_put = False
    assert remote.sync(root=root).sent == 1 and CID in fake.calls and remote.restore_calls() == []


@pytest.mark.parametrize("status", ["recorded", "processing", None])
def test_busy_calls_are_not_trashed(fake, root, data, tmp_path, status):
    d = make_call(root, CID, CID, status=status or "done")
    if status is None:  # being recorded: no call.json yet
        (d / "call.json").unlink()
    fake.gone[CID] = "2026-11-05T10:00:00Z"
    trash = FakeTrash(tmp_path / "Trash")
    fake.requests.clear()
    assert remote.sync(root=root, trash=trash).trashed == 0
    assert d.is_dir() and not trash.moved
    assert not [r for r in fake.requests if r[0] in ("PUT", "POST", "DELETE")]
    (d / "call.json").write_text(json.dumps({"schema": 1, "id": CID, "status": "done"}))
    assert remote.sync(root=root, trash=trash).trashed == 1, "the next sync, once it is done"


def test_trash_failure_is_a_status_line_and_nothing_is_uploaded(fake, root, data):
    d = make_call(root, CID, CID)
    fake.gone[CID] = "2026-11-05T10:00:00Z"

    def broken(path):
        raise PermissionError("no access")
    lines = []
    assert tuple(remote.sync(root=root, trash=broken, status=lines.append)) == (0, 0, 0, 0, 0)
    assert d.is_dir() and CID not in fake.calls and any("no access" in line for line in lines)
    assert remote._trashed() == {}, "retried next sync"


def test_server_older_than_0_3_keeps_the_old_behaviour(fake, root, data):
    fake.old = True
    make_call(root, CID, CID)
    assert tuple(remote.sync(root=root)) == (1, 0, 0, 0, 0), "no tombstones known: uploaded, never trashed"
    assert CID in fake.calls and not remote.trashed_file().exists()


def test_push_of_a_deleted_call(fake, root, capsys, monkeypatch):
    d = make_call(root, CID, CID, notes=[note("n")])
    fake.gone[CID] = "x"
    with pytest.raises(remote.Gone):
        remote.push(d)
    assert remote.push_notes(d) is False
    logs = []
    remote.push_after_transcription(d, logs.append)
    assert logs and "только на этом Mac" in logs[0]


def test_move_to_trash_falls_back_to_a_free_name_in_dot_trash(tmp_path, monkeypatch):
    home = tmp_path / "home"
    (home / ".Trash" / "2026-11-04 15-01").mkdir(parents=True)  # a folder with this name is there already
    monkeypatch.setattr(remote.Path, "home", classmethod(lambda cls: home))
    monkeypatch.setattr(remote.subprocess, "run", lambda *a, **kw: (_ for _ in ()).throw(OSError("no osascript")))
    d = make_call(tmp_path / "Calls", "2026-11-04 15-01", CID)
    REAL_MOVE_TO_TRASH(d)
    assert not d.exists()
    names = sorted(p.name for p in (home / ".Trash").iterdir())
    assert len(names) == 2 and names[0] == "2026-11-04 15-01" and names[1].startswith("2026-11-04 15-01 ")


# --- review fixes: a call deleted meanwhile, folder names, titles, failures, the payload whitelist ---

def test_lock_never_recreates_a_call_folder(root, data):
    from sozvon_engine import calls, jsonfile, notes
    gone = root / CID
    with pytest.raises(FileNotFoundError):
        with jsonfile.locked(calls.call_file(gone)):
            pass
    with pytest.raises(notes.CallGone):
        notes.add(gone, "заметка", "claude")
    assert notes.merge(gone, [note("n1")], []) is False
    assert not gone.exists(), "a call moved to the Trash never comes back as a stub folder"
    with jsonfile.locked(data / "sub" / "x.json"):  # inside the data folder folders are created
        pass
    empty = make_call(root, "2026-11-04 16-00", "2026-11-04 16-00")
    (empty / "call.json").unlink()  # the folder exists, its call.json is gone
    with pytest.raises(notes.CallGone):
        notes.add(empty, "заметка", "claude")
    assert notes.merge(empty, [note("n1")], []) is False
    assert not (empty / "call.json").exists()


def test_note_racing_a_move_to_the_trash(root, tmp_path):
    """add_note found the folder, then the app moved it to the Trash while add waited for the lock."""
    import threading
    import time as _time
    from sozvon_engine import calls, jsonfile, notes
    d = make_call(root, CID, CID)
    errors = []

    def add():
        try:
            notes.add(d, "заметка", "claude")
        except notes.NoteError as e:
            errors.append(e)
    with jsonfile.locked(calls.call_file(d)):
        th = threading.Thread(target=add)
        th.start()
        _time.sleep(0.3)  # add has opened the lock file and waits for it
        d.rename(tmp_path / "Trash-copy")
    th.join(5)
    assert errors and isinstance(errors[0], notes.CallGone)
    assert not d.exists(), "the folder is not recreated"
    assert "notes" not in read(tmp_path / "Trash-copy"), "nothing written into the trashed copy either"


def test_add_note_tool_reports_a_gone_call(root, monkeypatch):
    from sozvon_engine import calls
    from sozvon_engine.mcp import tools
    monkeypatch.setattr(calls, "find_call", lambda cid: root / CID)
    out = tools.add_note(CID, "заметка")
    assert "звонка больше нет" in out and not (root / CID).exists()


def test_stub_folder_does_not_cancel_a_server_delete(fake, root, data):
    fake.put(server_copy(CID))
    tombstone(data, CID)
    (root / CID).mkdir()  # only a call.json.lock left behind by an older engine
    (root / CID / "call.json.lock").write_text("")
    assert remote.sync(root=root).deleted == 1 and CID not in fake.calls


@pytest.mark.parametrize("name", [
    "2026-11-04 15-01 · Acme Corp",  # no-break space
    "2026-11-04 15-01 · 10 000 ₽",  # narrow no-break space
    "2026-11-04 15-01 · 👩‍💻 team",  # zero-width joiner
    "2026-11-04 15-01 · Café",
])
def test_folder_names_survive_a_restore(name):
    assert remote.safe_folder(name, CID) == name


def test_folder_drops_separators_and_leading_dots():
    assert remote.safe_folder(f"{CID} · a b c\x07", CID) == f"{CID} · abc"
    assert remote.safe_folder(f"..{CID} · x", CID) == f"{CID} · x"


def test_rename_does_not_resend_and_old_hashes_upgrade_once(fake, root):
    d = make_call(root, f"{CID} · Acme", CID)
    body = remote.payload(d)
    fake.put({**body, "hash": "0" * 64})  # stored by an older engine (folder in the hash)
    assert remote.sync(root=root).sent == 1
    assert remote.sync(root=root).sent == 0, "re-uploaded once, then in step"
    d.rename(root / f"{CID} · Acme · renamed")
    assert remote.sync(root=root).sent == 0, "a rename alone never resends the call"


def test_payload_sends_only_whitelisted_fields(root):
    d = make_call(root, CID, CID)
    full = {**read(d), "created_at": "2026-11-04T11:01:13Z", "terms": "secret words", "languages": "ru,en",
            "summary": True, "info_pending": True, "engine": {"version": "x", "model": "turbo"}, "profile": "acme",
            "names": ["Анна"], "participants": ["Анна Петрова", "Влад"],
            "audio": {"mic_start": 1.5, "system_start": 1.4, "mic_seconds": 61.0, "system_seconds": 62.5},
            "future_field": 1, "notes": [note("n1")]}
    (d / "call.json").write_text(json.dumps(full, ensure_ascii=False))
    body = remote.payload(d)
    assert body["call"] == {"schema": 1, "id": CID, "created_at": "2026-11-04T11:01:13Z", "status": "done",
                            "profile": "acme", "names": ["Анна"], "participants": ["Анна Петрова", "Влад"],
                            "topic": "запуск", "languages": "ru,en",
                            "summary": True, "audio": {"mic_seconds": 61, "system_seconds": 62.5}}
    assert body["notes"] == [note("n1")]


def test_old_calls_send_durations_from_meta_json(root):
    d = make_call(root, CID, CID)
    (d / "meta.json").write_text(json.dumps({"mic_seconds": 30.0, "mic_start": 2.0}))
    assert remote.payload(d)["call"]["audio"] == {"mic_seconds": 30}


def test_restore_keeps_only_whitelisted_fields_and_is_in_step(fake, root, data):
    call = {"schema": 1, "id": CID, "status": "done", "topic": "запуск", "info_pending": True, "terms": "t",
            "engine": {"model": "turbo"}, "audio": {"mic_seconds": 61.0, "mic_start": 3.0}}
    fake.put(server_copy(CID, call=call))
    assert remote.sync(root=root).downloaded == 1
    d = next(root.iterdir())
    assert read(d) == {"schema": 1, "id": CID, "status": "done", "topic": "запуск", "audio": {"mic_seconds": 61}}
    fake.put(server_copy(CID, call=remote.call_fields(call)))  # as a new engine stores it
    fake.requests.clear()
    assert remote.sync(root=root).sent == 0, "a downloaded call is not uploaded back"


def test_two_macs_with_different_titles_do_not_ping_pong(fake, tmp_path, data, monkeypatch):
    fake.version = "0.3.3"  # keeps titles
    a, b = tmp_path / "A", tmp_path / "B"
    pa, pb = tmp_path / "data-a", tmp_path / "data-b"
    for r, p, title in ((a, pa, "Acme Corp"), (b, pb, "Acme Inc")):
        (p / "profiles").mkdir(parents=True)
        (p / "profiles" / "acme.json").write_text(json.dumps({"title": title}))
        d = make_call(r, CID, CID)
        (d / "call.json").write_text(json.dumps({**read(d), "profile": "acme"}))

    def run(root, p):
        monkeypatch.setenv("SOZVON_DATA_DIR", str(p))
        return remote.sync(root=root).sent
    assert run(a, pa) == 1
    assert run(b, pb) == 1, "first time: B's own title is sent once"
    assert [run(a, pa), run(b, pb), run(a, pa), run(b, pb)] == [0, 0, 0, 0], "no ping-pong"
    (pa / "profiles" / "acme.json").write_text(json.dumps({"title": "Acme Group"}))
    assert run(a, pa) == 1 and fake.calls[CID]["project_title"] == "Acme Group", "a title changed here is sent"
    assert run(b, pb) == 0


def test_one_bad_call_does_not_block_the_others(fake, root, data, capsys):
    make_call(root, "2026-11-04 15-01", "2026-11-04 15-01")
    make_call(root, "2026-11-04 16-00", "2026-11-04 16-00")
    fake.put(server_copy("2026-01-01 10-00"))
    fake.put(server_copy("2026-01-02 10-00"))
    fake.fail_ids = {"2026-11-04 16-00": 413, "2026-01-01 10-00": 500}
    assert remote.main() == 1
    lines = capsys.readouterr().out.strip().splitlines()
    assert lines[-1] == "RESULT: ok 1 0 1 0 2"
    assert [line for line in lines if "2026-11-04 16-00" in line and "413" in line]
    assert [line for line in lines if "2026-01-01 10-00" in line and "500" in line]
    assert "2026-11-04 15-01" in fake.calls and (root / "2026-01-02 10-00 · Acme · запуск").is_dir()
    fake.fail_ids = {}
    assert remote.main() == 0
    assert capsys.readouterr().out.strip().splitlines()[-1] == "RESULT: ok 1 0 1 0 0"


def test_a_server_that_stops_answering_stops_the_sync(fake, root, monkeypatch):
    for i in range(5):
        make_call(root, f"2026-11-04 1{i}-00", f"2026-11-04 1{i}-00")
    real = remote._request
    seen = []

    def down(srv, method, path, *a, **kw):
        if method == "PUT":
            seen.append(path)
            raise remote.Unreachable(1, "timed out")
        return real(srv, method, path, *a, **kw)
    monkeypatch.setattr(remote, "_request", down)
    with pytest.raises(remote.Unreachable):
        remote.sync(root=root)
    assert len(seen) == remote.MAX_UNREACHABLE


def test_wrong_password_mid_sync_stops_it(fake, root, monkeypatch):
    make_call(root, CID, CID)
    fake.fail_ids = {CID: 401}
    with pytest.raises(remote.RemoteError) as e:
        remote.sync(root=root)
    assert e.value.code == 2


def test_call_json_without_status_is_busy(fake, root, data, tmp_path):
    d = make_call(root, CID, CID, transcript=None)
    (d / "call.json").write_text(json.dumps({"schema": 1, "id": CID}))  # the app writes status later
    fake.gone[CID] = "2026-11-05T10:00:00Z"
    trash = FakeTrash(tmp_path / "Trash")
    assert remote.sync(root=root, trash=trash).trashed == 0 and d.is_dir()
    (d / "transcript.txt").write_text("[00:00] Я: Привет.\n")  # an old finished call without a status
    assert remote.sync(root=root, trash=trash).trashed == 1


def test_trashed_list_is_written_after_each_move(fake, root, data, tmp_path):
    for cid in ("2026-11-04 15-01", "2026-11-04 16-00"):
        make_call(root, cid, cid)
        fake.gone[cid] = "2026-11-05T10:00:00Z"
    seen = []

    def trash(path):
        seen.append(set(remote._trashed()))
        if len(seen) == 2:
            raise KeyboardInterrupt  # the sync is killed while moving the second call
        Path(path).rename(tmp_path / Path(path).name)
    with pytest.raises(KeyboardInterrupt):
        remote.sync(root=root, trash=trash)
    assert seen[1] == {"2026-11-04 15-01"} and set(remote._trashed()) == {"2026-11-04 15-01"}


def test_notes_over_the_limit(fake, root, data):
    from sozvon_engine import notes as notes_mod
    many = [note(f"n{i:03}", at=f"2026-11-05T00:{i // 60:02}:{i % 60:02}Z") for i in range(230)]
    d = make_call(root, CID, CID, notes=many[:150])
    assert notes_mod.merge(d, many[150:], []) is True
    kept = [n["id"] for n in read(d)["notes"]]
    assert len(kept) == 200 and kept[0] == "n030" and kept[-1] == "n229", "the newest 200 are kept"
    assert len(remote.payload(d)["notes"]) == 200
    # an older server that already holds 200 other notes of this call ignores more: not sent again and again
    fake.put({**remote.payload(d), "notes": []})
    fake.merge(CID, [note(f"s{i:03}", at="2026-11-06T00:00:00Z") for i in range(200)], [])
    real_fetch = remote.fetch
    remote.fetch = lambda srv, cid: {**real_fetch(srv, cid), "notes": []}  # pulled notes are not the point here
    try:
        fake.requests.clear()
        assert remote.sync(root=root).sent == 0
        assert not [r for r in fake.requests if r[0] == "POST"]
    finally:
        remote.fetch = real_fetch


def test_newer_server_gets_the_newest_notes(fake, root, data):
    fake.version = "0.3.3"
    d = make_call(root, CID, CID, notes=[note("late", at="2026-11-07T00:00:00Z")])
    fake.put({**remote.payload(d), "notes": []})
    fake.merge(CID, [note(f"s{i:03}", at="2026-11-06T00:00:00Z") for i in range(200)], [])
    assert remote.sync(root=root).sent == 1, "a 0.3.3 server keeps the newest 200, so the new note is sent"
    assert "late" in fake.notes[CID]


def test_whole_seconds_hash_like_the_server_stores_them(root):
    """JavaScript writes 61.0 as 61: a restored call must not differ from the original by that."""
    a = make_call(root, "2026-11-04 15-01", CID)
    (a / "call.json").write_text(json.dumps({**read(a), "audio": {"mic_seconds": 61.0, "system_seconds": 1755.6}}))
    b = make_call(root / "other", "2026-11-04 15-01", CID)
    (b / "call.json").write_text(json.dumps({**read(b), "audio": {"mic_seconds": 61, "system_seconds": 1755.6}}))
    assert remote.payload(a)["hash"] == remote.payload(b)["hash"]


def test_titles_sent_to_an_old_server_are_not_remembered(tmp_path, monkeypatch):
    from sozvon_engine import remote
    saved = {}
    monkeypatch.setattr(remote, "_save_titles", lambda titles: saved.update({"t": titles}))
    monkeypatch.setattr(remote, "_sent_titles", lambda: {"x": "Acme"})
    monkeypatch.setattr(remote, "health", lambda srv: "0.3.1")
    monkeypatch.setattr(remote, "remote_state", lambda srv: ({}, {}))
    monkeypatch.setattr(remote, "_sync", lambda *a: None)
    root = tmp_path / "Calls"
    root.mkdir()
    remote.sync(remote.Server("https://example.test", "pw"), root=root)
    assert saved["t"] == {}
