"""Projects: profiles/<slug>.json with fields title, context, people, terms, replacements.

Project names are limited to [a-z0-9_-]{1,64}: otherwise "../" could read and overwrite other files.
Writes are atomic, the file has "schema": 1.
"""
import re
from contextlib import contextmanager
from pathlib import Path

from . import i18n, jsonfile, paths, vocab

SLUG = re.compile(r"[a-z0-9_-]{1,64}")


def valid_slug(slug) -> bool:
    return isinstance(slug, str) and bool(SLUG.fullmatch(slug))


def to_slug(text) -> str:
    """File name from an arbitrary string (assistant reply): allowed characters only."""
    return re.sub(r"[^a-z0-9_-]", "", str(text).lower())[:64]


def root() -> Path:
    return paths.engine_dir().profiles


def file(slug) -> Path:
    if not valid_slug(slug):
        raise ValueError(i18n.t("bad_profile_name", name=slug))
    return root() / f"{slug}.json"


def load(slug) -> dict:
    """Project or {} (no name, invalid name, missing file, broken file)."""
    if not slug or not valid_slug(slug):
        return {}
    return jsonfile.read(file(slug), default={}) or {}


def save(slug, prof: dict) -> None:
    jsonfile.write_atomic(file(slug), jsonfile.with_schema(prof))


@contextmanager
def editing(slug):
    """Edit a project under lock: fresh copy from disk, written on exit if changed.

    No project (or invalid name): {} and nothing is written.
    """
    with jsonfile.locked(file(slug)):
        prof = load(slug)
        before = jsonfile.with_schema(prof) if prof else None
        yield prof
        if prof and jsonfile.with_schema(prof) != before:
            save(slug, prof)


def list_all() -> dict:
    """{slug: title} of all projects."""
    out = {}
    d = root()
    for f in sorted(d.glob("*.json")) if d.is_dir() else []:
        if not valid_slug(f.stem):
            continue
        data = jsonfile.read(f)
        if data is not None:
            out[f.stem] = data.get("title", f.stem)
    return out


def learn_people(slug: str, prof: dict, names: list, me: str) -> list:
    """The project learns by itself: new call participants are appended to people. -> added names.

    Compared and written against a fresh copy from disk under lock; prof is updated in memory.
    """
    if not slug or not prof or not names or not valid_slug(slug):
        return []
    with editing(slug) as fresh:
        if not fresh:
            return []
        added = vocab.new_call_people(fresh.get("people", []), names, me)
        if added:
            fresh["people"] = list(fresh.get("people", [])) + added
    prof["people"] = list(fresh.get("people", []))
    return added


def merge_found(prof: dict, item: dict) -> bool:
    """Append people, terms and replacements from project discovery to an existing project. -> whether changed."""
    people, np_ = vocab.merge_people(prof.get("people", []), clean_list(item.get("people")))
    terms, nt = vocab.merge_terms(prof.get("terms", []), clean_list(item.get("terms"))[:25])
    reps, nr = vocab.merge_replacements(prof.get("replacements", []), item.get("replacements") or [])
    prof.update(people=people, terms=terms, replacements=reps)
    return bool(np_ or nt or nr)


def from_found(slug: str, item: dict) -> dict:
    """New project from a project discovery reply."""
    reps, _ = vocab.merge_replacements([], item.get("replacements") or [])
    return {"title": item.get("title") or slug, "context": str(item.get("context", "")),
            "people": vocab.merge_people([], clean_list(item.get("people")))[0],
            "terms": vocab.merge_terms([], clean_list(item.get("terms")))[0][:25],
            "replacements": reps}


def clean_list(value) -> list:
    return [str(x) for x in (value or []) if x] if isinstance(value, list) else []
