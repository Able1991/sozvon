"""Voice prints on the own server (server 0.4.0+, docs/CONTRACT.md section 6).

  GET    {url}/api/voices        -> {"voices": [record | {id, deleted: true, updated_at}]}
  PUT    {url}/api/voices/{id}   <- one record; 409 answers with the server's record
  DELETE {url}/api/voices/{id}

Called from remote.sync after the calls and the audio; the request helpers and errors stay in remote.py.
"""
import urllib.parse

from . import remote
from .i18n import t

VOICES_VERSION = (0, 4, 0)


def _voice_path(vid: str) -> str:
    return "/api/voices/" + urllib.parse.quote(vid, safe="")


def remote_voices(srv: remote.Server) -> tuple[dict, dict]:
    """GET /api/voices -> ({id: record}, {id: deleted at})."""
    from . import voices
    _, j = remote._request(srv, "GET", "/api/voices")
    items = j.get("voices") if isinstance(j, dict) else None
    if not isinstance(items, list):
        raise remote.RemoteError(1, t("remote_bad_reply", path="/api/voices"))
    recs, tombs = {}, {}
    for v in items:
        if not isinstance(v, dict) or not isinstance(v.get("id"), str):
            continue
        if v.get("deleted") is True:
            tombs[v["id"]] = str(v.get("updated_at") or "")
        elif (rec := voices.valid({**v, "schema": 1})) is not None:
            recs[rec["id"]] = rec
    return recs, tombs


def _voice_body(rec: dict) -> dict:
    return {k: rec[k] for k in ("id", "name", "profile", "me", "embedding", "seconds", "updated_at")}


def _put_voice(srv: remote.Server, rec: dict) -> bool:
    """PUT one voice print. -> True if the server took it.

    409: another Mac changed the same record after this one (two enrollments at once); the server answers with
    its record. The two prints are merged (voices.merge_embeddings), stored here and sent once more; a second
    conflict waits for the next sync."""
    from . import voices
    for attempt in range(2):
        code, j = remote._request(srv, "PUT", _voice_path(rec["id"]), _voice_body(rec), missing_ok=True, conflict_ok=True)
        if code != 409:
            return code not in (404, 405, 410)
        stored = voices.valid({**j["voice"], "schema": 1}) if isinstance(j, dict) and isinstance(j.get("voice"), dict) else None
        if attempt or stored is None or stored["id"] != rec["id"]:
            return False
        rec = voices.merge_remote(stored, rec)
        if rec is None:
            return False
    return False


def sync_voices(srv: remote.Server, status, enabled: bool = False) -> tuple[int, int, int]:
    """Make the voice prints here and on the server agree. -> (sent, downloaded, deleted).

    Deletions made here (voices-deleted.json) always go to the server, even with SOZVON_SYNC_VOICES=0, so a
    deleted voice is deleted everywhere. With sync on (SOZVON_SYNC_VOICES=1, off by default): server tombstones delete the record here unless it
    changed here later, records the server lacks or holds older go up, records missing here or newer there
    come down (never over a newer one here). A failure is a STATUS line; the calls' RESULT numbers stay as
    they are. A wrong password still stops the sync.
    """
    from . import voices
    sent = downloaded = deleted = 0
    try:
        theirs, their_tombs = remote_voices(srv)

        def send_tombstones():
            n, done = 0, []
            for vid in voices.tombstones():
                if vid in theirs or vid not in their_tombs:
                    remote._request(srv, "DELETE", _voice_path(vid), missing_ok=True)
                    theirs.pop(vid, None)
                    their_tombs[vid] = voices.now()
                    n += 1
                done.append(vid)
            voices.forget_tombstones(done)
            return n
        deleted += send_tombstones()
        if enabled:
            local = {r["id"]: r for r in voices.load_all()}
            dead = {vid: at for vid, at in their_tombs.items()
                    if vid in local and voices.timestamp(local[vid]["updated_at"]) <= voices.timestamp(at)}
            deleted += voices.drop_local(dead)
            for vid in dead:
                local.pop(vid, None)
            for vid, rec in sorted(theirs.items()):
                mine = local.get(vid)
                if mine is not None and (voices.content_hash(mine) == voices.content_hash(rec)
                                         or voices.timestamp(mine["updated_at"]) >= voices.timestamp(rec["updated_at"])):
                    continue
                if voices.accept_remote(rec):
                    downloaded += 1
            deleted += send_tombstones()  # ids folded into a record here
            for rec in voices.load_all():
                if not voices.is_current(rec):  # the own server holds prints of one model only
                    continue
                r = theirs.get(rec["id"])
                if r is not None and (voices.content_hash(r) == voices.content_hash(rec)
                                      or voices.timestamp(r["updated_at"]) > voices.timestamp(rec["updated_at"])):
                    continue
                if _put_voice(srv, rec):
                    sent += 1
    except remote.RemoteError as e:
        if e.code == 2:
            raise
        status(t("remote_status_voices_failed", err=e.message))
        return sent, downloaded, deleted
    if sent or downloaded or deleted:
        status(t("remote_status_voices", sent=sent, downloaded=downloaded, deleted=deleted))
    return sent, downloaded, deleted
