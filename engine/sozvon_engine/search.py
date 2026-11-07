"""Ranked search over call transcripts and summaries: an SQLite FTS5 index in <data>/index.db.

The lexical part of session-rag (MIT, same author), where it was measured on Russian and English
text: Snowball-stemmed BM25 for the query and for each alternative phrasing, Reciprocal Rank Fusion
of those lists, then re-ranking by "coverage" (the share of query words present in a chunk).
Phrasings lifted hit@3 from 60% to 83% on one project, coverage added 10-17 pt hit@1; BM25 alone
over-rewards one rare term. Vectors and rerankers did not pay off there and are not ported.

The index is a cache. Chunks: one per transcript.txt line ("[MM:SS] Name: text"), one per
summary.md line (kind "summary", the section heading in place of the speaker) and one per note in
call.json (kind "note", the date in place of the timestamp and the note's source as the speaker). Before every search
the index is synced with the calls folder under a flock: a call folder is reindexed when the
mtime or size of its call.json, transcript.txt or summary.md changes, and dropped when it is gone.
A broken index or another schema version is rebuilt from scratch.
"""
import os
import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path

from . import calls, jsonfile, notes, paths
from .textproc import fts_query, stem_text, words

SCHEMA = 2  # 2: notes are indexed
RRF_K = 60
POOL = 80
COVERAGE_WEIGHT = 0.5  # share of query words in a chunk, blended with the fused BM25 rank
VARIANT_WEIGHT = 1.0  # weight of alternative phrasings relative to the query (session-rag default)
FILES = ("call.json", "transcript.txt", "summary.md")

DDL = f"""
CREATE TABLE calls (folder TEXT PRIMARY KEY, id TEXT NOT NULL, sig TEXT NOT NULL,
                    topic TEXT NOT NULL, profile TEXT NOT NULL);
CREATE TABLE chunks (id INTEGER PRIMARY KEY, folder TEXT NOT NULL, kind TEXT NOT NULL,
                     ts TEXT NOT NULL, speaker TEXT NOT NULL, text TEXT NOT NULL);
CREATE INDEX chunks_folder ON chunks(folder);
CREATE VIRTUAL TABLE chunks_fts USING fts5(stem, tokenize='unicode61 remove_diacritics 2');
PRAGMA user_version = {SCHEMA};
"""

# One space after "]" and after the speaker, as render.py writes them; "\s+(.+?)" was quadratic on
# long runs of spaces in a hand-edited transcript.
LINE = re.compile(r"^\[(\d+:\d{2}(?::\d{2})?)\]\s(\S.*?):\s(.*)$")


@dataclass
class Hit:
    call_id: str
    kind: str  # "transcript", "summary" or "note"
    ts: str
    speaker: str  # summary: section heading; note: its source
    text: str
    topic: str
    profile: str
    score: float


def index_path() -> Path:
    return paths.engine_dir().index


# --- index ---

def _connect(path: Path) -> sqlite3.Connection:
    os.close(os.open(path, os.O_RDWR | os.O_CREAT, 0o600))  # created private before SQLite opens it
    return sqlite3.connect(path)


def _remove(path: Path) -> None:
    for suffix in ("", "-journal", "-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)


def open_index(path: Path) -> sqlite3.Connection:
    """Connection to the index; a broken file or another schema version is replaced by an empty index."""
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        con = _connect(path)
        try:
            if con.execute("PRAGMA user_version").fetchone()[0] == SCHEMA:
                return con
        except sqlite3.DatabaseError:
            pass
        con.close()
    except sqlite3.DatabaseError:
        pass
    _remove(path)
    con = _connect(path)
    con.executescript(DDL)
    return con


def _signature(d: Path) -> str:
    out = []
    for name in FILES:
        try:
            st = (d / name).stat()
            out.append(f"{st.st_mtime_ns}:{st.st_size}")
        except OSError:
            out.append("-")
    return " ".join(out)


def _read(f: Path) -> str:
    try:
        return f.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def chunks(d: Path, call: dict | None = None) -> list[tuple[str, str, str, str]]:
    """(kind, ts, speaker, text) of a call folder: transcript lines, summary lines, then notes."""
    out = []
    for line in _read(d / "transcript.txt").splitlines():
        line = line.strip()
        if not line:
            continue
        m = LINE.match(line)
        out.append(("transcript", *m.groups()) if m else ("transcript", "", "", line))
    section = ""
    for line in _read(d / "summary.md").splitlines():
        line = line.strip()
        if line.startswith("#"):
            section = line.lstrip("#").strip()
        elif line and line.strip("-*_ ") != "":
            out.append(("summary", "", section, line))
    for n in notes.notes_of(call if call is not None else calls.read_call(d)):
        out.append(("note", n["at"][:10], n["source"], " ".join(n["text"].split())))
    return out


def _drop(con: sqlite3.Connection, folder: str) -> None:
    con.execute("DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE folder = ?)", (folder,))
    con.execute("DELETE FROM chunks WHERE folder = ?", (folder,))
    con.execute("DELETE FROM calls WHERE folder = ?", (folder,))


def _index_call(con: sqlite3.Connection, d: Path, sig: str) -> None:
    _drop(con, d.name)
    c = calls.read_call(d)
    con.execute("INSERT INTO calls VALUES (?, ?, ?, ?, ?)",
                (d.name, c["id"], sig, str(c.get("topic") or ""), str(c.get("profile") or "")))
    for kind, ts, speaker, text in chunks(d, c):
        cur = con.execute("INSERT INTO chunks (folder, kind, ts, speaker, text) VALUES (?, ?, ?, ?, ?)",
                          (d.name, kind, ts, speaker, text))
        con.execute("INSERT INTO chunks_fts (rowid, stem) VALUES (?, ?)",
                    (cur.lastrowid, stem_text(f"{speaker} {text}")))


def sync(con: sqlite3.Connection, root: Path) -> int:
    """Bring the index in line with the calls folder. -> number of reindexed or dropped calls.

    Nothing changed: one directory listing and a few stat calls per call, no file is read.
    """
    known = dict(con.execute("SELECT folder, sig FROM calls"))
    seen, changed = set(), 0
    with con:
        if root.is_dir():
            for d in root.iterdir():
                if d.name.startswith(".") or not d.is_dir():
                    continue
                seen.add(d.name)
                sig = _signature(d)
                if known.get(d.name) != sig:
                    _index_call(con, d, sig)
                    changed += 1
        for folder in known.keys() - seen:
            _drop(con, folder)
            changed += 1
    return changed


# --- ranking ---

def _bm25(con: sqlite3.Connection, query: str, pool: int) -> list[int]:
    fq = fts_query(query)
    if not fq:
        return []
    rows = con.execute("SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?", (fq, pool))
    return [r[0] for r in rows]


def _norm(text: str) -> str:
    return " ".join(text.lower().split())[:400]


def rank(con: sqlite3.Connection, queries: list[str], limit: int, coverage: float = COVERAGE_WEIGHT,
         variant_weight: float = VARIANT_WEIGHT, pool: int = POOL) -> list[Hit]:
    """Hits for the query (queries[0]) and its alternative phrasings, best first."""
    scores: dict[int, float] = {}
    for n, query in enumerate(queries):  # Reciprocal Rank Fusion; phrasings count with variant_weight
        w = 1.0 if n == 0 else variant_weight
        for pos, i in enumerate(_bm25(con, query, pool)):
            scores[i] = scores.get(i, 0.0) + w / (RRF_K + pos)
    if not scores:
        return []
    q = ",".join("?" * len(scores))
    # q is only "?" placeholders; the ids go in as parameters.
    meta = {r[0]: r for r in con.execute(  # nosemgrep: python.sqlalchemy.security.sqlalchemy-execute-raw-query.sqlalchemy-execute-raw-query
        f"""SELECT k.id, c.id, k.kind, k.ts, k.speaker, k.text, c.topic, c.profile
            FROM chunks k JOIN calls c ON c.folder = k.folder WHERE k.id IN ({q})""", list(scores))}
    top = max(scores.values())
    qwords = [s for s in ({w for w in words(query) if len(w) > 2} for query in queries) if s]

    def score(i: int) -> float:
        base = scores[i] / top
        if coverage and qwords:
            have = set(words(f"{meta[i][4]} {meta[i][5]}"))
            cov = max(len(s & have) / len(s) for s in qwords)
            base = coverage * cov + (1 - coverage) * base
        return base

    out, seen = [], set()
    for i in sorted((i for i in scores if i in meta), key=score, reverse=True):
        r = meta[i]
        key = (r[1], _norm(r[5]))  # the same words twice in one call: keep the better one
        if key in seen:
            continue
        seen.add(key)
        out.append(Hit(call_id=r[1], kind=r[2], ts=r[3], speaker=r[4], text=r[5], topic=r[6], profile=r[7],
                       score=score(i)))
        if len(out) >= limit:
            break
    return out


def search(text: str, also: list[str] | None = None, limit: int = 20, root: Path | None = None,
           index: Path | None = None) -> list[Hit]:
    """Sync the index with the calls folder, then rank chunks for text and its alternative phrasings.

    Raises ImportError/sqlite3.Error when the index can't work here (e.g. no FTS5): the caller falls back.
    """
    queries = list(dict.fromkeys(q.strip() for q in [text, *(also or [])] if q and q.strip()))
    if not queries:
        return []
    root = Path(root or paths.calls_dir())
    index = Path(index or index_path())
    index.parent.mkdir(parents=True, exist_ok=True)
    with jsonfile.locked(index):
        for attempt in (1, 2):
            con = None
            try:
                con = open_index(index)
                sync(con, root)
                return rank(con, queries, limit)
            except sqlite3.DatabaseError as e:
                # Only a damaged file is worth deleting. "Disk full" or "database is locked" would
                # otherwise wipe and rebuild the whole index on every search.
                if attempt == 2 or not _corrupt(e):
                    raise
                _remove(index)
            finally:
                if con is not None:
                    con.close()
    return []


def _corrupt(e: sqlite3.DatabaseError) -> bool:
    """The index file is damaged or from another schema, not just busy or out of space."""
    msg = str(e).lower()
    return any(s in msg for s in ("malformed", "not a database", "no such table", "no such column"))
