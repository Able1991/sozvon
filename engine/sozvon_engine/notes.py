"""Call notes: comments on a call in call.json["notes"] (docs/CONTRACT.md, section 4).

A note is {"id": uuid4, "at": ISO 8601 UTC, "text": "...", "source": "claude-code|codex|app|..."}.
Notes are append-only: nobody edits one. The app or the delete_note tool deletes a note, and then its id goes to
call.json["notes_deleted"], a tombstone that sync carries to the server (docs/SERVER.md), so a copy
elsewhere can't bring it back. Every change is a read-modify-write of call.json under the
call.json.lock flock, which the app takes too.
"""
import re
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from . import calls, jsonfile

MAX_TEXT = 4000  # characters (code points) per note
MAX_NOTES = 200  # per call
MAX_SOURCE = 40
ID_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")
KNOWN_SOURCES = (("claude-code", "claude-code"), ("claude code", "claude-code"), ("codex", "codex"),
                 ("chatgpt", "chatgpt"), ("openai", "chatgpt"), ("claude", "claude"))


class NoteError(ValueError):
    """The note can't be added: empty, too long, too many, or the call is gone."""


class CallGone(NoteError):
    """The call folder or its call.json is gone (moved to the Trash meanwhile): nothing is written."""


def _check_present(d: Path) -> None:
    """Under the lock: the call must still be there, or nothing is written (never a stub call.json)."""
    from .i18n import t
    if not calls.call_file(d).is_file():
        raise CallGone(t("note_call_gone"))


def newest(items: list[dict], limit: int = MAX_NOTES) -> list[dict]:
    """At most limit notes, the newest by (at, id), oldest first: the server keeps the same ones."""
    return sorted(sorted(items, key=lambda n: (n["at"], n["id"]))[-limit:], key=lambda n: n["at"]) if items else []


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def source_name(raw: str | None) -> str:
    """Short lowercase source from an MCP client name: "claude-code", "codex", "claude", "chatgpt"..."""
    name = " ".join(str(raw or "").lower().replace("_", "-").split())
    for needle, source in KNOWN_SOURCES:
        if needle in name:
            return source
    name = re.sub(r"[^a-z0-9.-]+", "-", name).strip("-")[:MAX_SOURCE]
    return name or "assistant"


def clean(n) -> dict | None:
    """A valid note with only the four fields, or None."""
    if not isinstance(n, dict):
        return None
    nid, at, text, source = n.get("id"), n.get("at"), n.get("text"), n.get("source")
    if not isinstance(nid, str) or not ID_RE.match(nid):
        return None
    if not isinstance(at, str) or not at.strip() or len(at) > 40:
        return None
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
        return None
    if not isinstance(source, str) or len(source) > MAX_SOURCE:
        source = "assistant"
    return {"id": nid, "at": at, "text": text, "source": source or "assistant"}


def notes_of(call: dict) -> list[dict]:
    """Valid notes of a call.json object, each id once, oldest first."""
    raw = call.get("notes")
    out, seen = [], set()
    for n in raw if isinstance(raw, list) else []:
        c = clean(n)
        if c and c["id"] not in seen:
            seen.add(c["id"])
            out.append(c)
    return sorted(out, key=lambda n: n["at"])


def deleted_of(call: dict) -> list[str]:
    """Ids of notes deleted in the app (tombstones)."""
    raw = call.get("notes_deleted")
    return list(dict.fromkeys(i for i in (raw if isinstance(raw, list) else []) if isinstance(i, str) and ID_RE.match(i)))


@contextmanager
def editing(d: Path):
    """call.json for a read-modify-write under its flock; written back only if the block succeeds.

    A broken call.json raises jsonfile.JsonFileError instead of being replaced. A call that is gone
    (folder or call.json missing, e.g. moved to the Trash a moment ago) raises CallGone and is never
    recreated.
    """
    from .i18n import t
    d = Path(d)
    try:
        with jsonfile.locked(calls.call_file(d)):
            _check_present(d)
            call = calls.read_call(d, strict=True)
            yield call
            calls.write_call(d, call)
    except FileNotFoundError:
        raise CallGone(t("note_call_gone")) from None


def add(d: Path, text: str, source: str) -> dict:
    """Append a note to the call in folder d. -> the note. NoteError when it can't be added."""
    from .i18n import t
    text = (text or "").strip()
    if not text:
        raise NoteError(t("note_empty"))
    if len(text) > MAX_TEXT:
        raise NoteError(t("note_too_long", n=MAX_TEXT))
    note = {"id": str(uuid.uuid4()), "at": now(), "text": text, "source": source_name(source)}
    with editing(d) as call:
        have = notes_of(call)
        if len(have) >= MAX_NOTES:
            raise NoteError(t("note_too_many", n=MAX_NOTES))
        call["notes"] = have + [note]
    return note


def merge(d: Path, incoming: list, tombstones) -> bool:
    """Add notes the call lacks (by id) and apply tombstones. -> whether call.json changed.

    Never drops a note it has unless its id is tombstoned, or it is older than the newest MAX_NOTES
    (the server keeps the same newest ones). A call that is gone (moved to the Trash meanwhile) is
    skipped: False, and nothing is recreated.
    """
    gone = set(tombstones or ())
    d = Path(d)
    try:
        return _merge(d, incoming, gone)
    except FileNotFoundError:
        return False


def _merge(d: Path, incoming: list, gone: set) -> bool:
    with jsonfile.locked(calls.call_file(d)):
        if not calls.call_file(d).is_file():
            return False
        call = calls.read_call(d, strict=True)
        have = notes_of(call)
        deleted = deleted_of(call)
        dead = gone | set(deleted)
        merged = [n for n in have if n["id"] not in dead]
        ids = {n["id"] for n in have}
        for n in incoming or ():
            c = clean(n)
            if c and c["id"] not in ids and c["id"] not in dead:
                ids.add(c["id"])
                merged.append(c)
        merged = newest(merged)
        new_deleted = deleted + sorted(gone - set(deleted))
        if merged == have and new_deleted == deleted:
            return False
        call["notes"] = merged
        call["notes_deleted"] = new_deleted
        calls.write_call(d, call)
    return True


def delete(d: Path, note_id: str) -> None:
    """Delete a note of the call in folder d, leaving a tombstone. NoteError when there is no such note."""
    from .i18n import t
    note_id = (note_id or "").strip()
    d = Path(d)
    if not ID_RE.match(note_id) or note_id not in {n["id"] for n in notes_of(calls.read_call(d))}:
        raise NoteError(t("note_not_found", id=note_id))
    merge(d, [], {note_id})


def format_section(items: list[dict], heading: str) -> str:
    """Notes for get_call: "## Notes" and one "- date time · source · id: text" line per note
    (the id is what delete_note takes)."""
    lines = [f"## {heading}"]
    for n in items:
        when = n["at"][:16].replace("T", " ")
        lines.append(f"- {when} · {n['source']} · {n['id']}: {n['text']}")
    return "\n".join(lines)
