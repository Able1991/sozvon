"""Shared vocab.json dictionary and the rules for merging terms, replacements and people.

One place for the rules: used by the shared dictionary, projects (profiles.py), MCP tools
and project discovery. Comparison is case-insensitive.
"""
from contextlib import contextmanager
from pathlib import Path

from . import jsonfile, paths


def _key(s: str) -> str:
    return str(s).strip().casefold()


def valid_pair(pair) -> bool:
    return isinstance(pair, (list, tuple)) and len(pair) == 2 and bool(pair[0]) and bool(pair[1])


def merge_terms(existing: list, new: list, front: bool = False) -> tuple[list, list]:
    """Add new terms without duplicates. front: new ones go first (higher priority in the prompt).

    -> (resulting list, what was actually added).
    """
    have = {_key(t) for t in existing}
    added = []
    for t in new:
        t = str(t).strip()
        if t and _key(t) not in have:
            have.add(_key(t))
            added.append(t)
    return (added + list(existing) if front else list(existing) + added), added


def set_replacement(existing: list, wrong: str, right: str) -> tuple[list, str | None]:
    """Set a replacement: an entry with the same left side overwrites its right side. -> (result, previous right side or None)."""
    out, old = [], None
    for p in existing:
        if valid_pair(p) and _key(p[0]) == _key(wrong):
            if old is None:
                old = p[1]
                out.append([wrong, right])
            continue
        out.append(list(p) if isinstance(p, (list, tuple)) else p)
    if old is None:
        out.append([wrong, right])
    return out, old


def merge_replacements(existing: list, new: list) -> tuple[list, list]:
    """Add only replacements with a new left side (project discovery does not overwrite user edits)."""
    have = {_key(p[0]) for p in existing if valid_pair(p)}
    added = []
    for p in new:
        if valid_pair(p) and _key(p[0]) not in have:
            have.add(_key(p[0]))
            added.append([str(p[0]), str(p[1])])
    return list(existing) + added, added


def remove_replacement(existing: list, wrong: str) -> tuple[list, bool]:
    out = [p for p in existing if not (valid_pair(p) and _key(p[0]) == _key(wrong))]
    return out, len(out) != len(existing)


def merge_people(existing: list, new: list) -> tuple[list, list]:
    """People from project discovery: exact name match, case-insensitive."""
    return merge_terms(existing, new)


def new_call_people(existing: list, names: list, me: str) -> list:
    """Which call participants are not in the project yet. Never adds yourself.

    A first name alone is known when any project person has that word ("Anna" and "Anna Petrova"). A full
    name is known when a project person has the same words in any order, or is just its first name: two people
    with the same first name ("Александр Бородин", "Александр Иванов") are both kept.
    """
    def words(n) -> frozenset:
        return frozenset(_key(w) for w in str(n).split())
    people = [words(p) for p in existing if str(p).strip()]
    out = []
    for n in names:
        n = " ".join(str(n).split())
        if not n or _key(n) == _key(me):
            continue
        w, first = words(n), _key(n.split()[0])
        known = any(first in p for p in people) if len(w) == 1 else any(p == w or p == {first} for p in people)
        if not known:
            people.append(w)
            out.append(n)
    return out


def all_replacements(vocab: dict, prof: dict) -> list:
    """Call replacements: shared ones from vocab.json plus the project's."""
    return [p for p in list(vocab.get("replacements", [])) + list(prof.get("replacements", [])) if valid_pair(p)]


# ---------- vocab.json storage ----------

def path() -> Path:
    return paths.engine_dir().vocab


def load() -> dict:
    """Read on every call: edits apply immediately."""
    return jsonfile.read(path(), default={}) or {}


def save(vocab: dict) -> None:
    jsonfile.write_atomic(path(), jsonfile.with_schema(vocab))


@contextmanager
def editing():
    """Edit vocab.json under a lock: fresh copy from disk, written on exit if changed."""
    with jsonfile.locked(path()):
        vocab = load()
        before = jsonfile.with_schema(vocab)
        yield vocab
        if jsonfile.with_schema(vocab) != before:
            save(vocab)
