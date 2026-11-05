"""Проекты: profiles/<slug>.json с полями title, context, people, terms, replacements.

Имя проекта только [a-z0-9_-]{1,64}: иначе через «../» можно читать и переписывать чужие файлы.
Запись атомарная, в файле "schema": 1.
"""
import re
from contextlib import contextmanager
from pathlib import Path

from . import i18n, jsonfile, paths, vocab

SLUG = re.compile(r"[a-z0-9_-]{1,64}")


def valid_slug(slug) -> bool:
    return isinstance(slug, str) and bool(SLUG.fullmatch(slug))


def to_slug(text) -> str:
    """Имя файла из произвольной строки (ответ помощника): только допустимые символы."""
    return re.sub(r"[^a-z0-9_-]", "", str(text).lower())[:64]


def root() -> Path:
    return paths.engine_dir().profiles


def file(slug) -> Path:
    if not valid_slug(slug):
        raise ValueError(i18n.t("bad_profile_name", name=slug))
    return root() / f"{slug}.json"


def load(slug) -> dict:
    """Проект или {} (нет имени, недопустимое имя, нет файла, битый файл)."""
    if not slug or not valid_slug(slug):
        return {}
    return jsonfile.read(file(slug), default={}) or {}


def save(slug, prof: dict) -> None:
    jsonfile.write_atomic(file(slug), jsonfile.with_schema(prof))


@contextmanager
def editing(slug):
    """Правка проекта под блокировкой: свежая копия с диска, запись при выходе, если изменилась.

    Нет проекта (или имя недопустимо): {} и ничего не записывается.
    """
    with jsonfile.locked(file(slug)):
        prof = load(slug)
        before = jsonfile.with_schema(prof) if prof else None
        yield prof
        if prof and jsonfile.with_schema(prof) != before:
            save(slug, prof)


def list_all() -> dict:
    """{slug: title} всех проектов."""
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
    """Проект учится сам: новые собеседники звонка дописываются в people. -> добавленные.

    Сравнение и запись по свежей копии с диска под блокировкой; prof обновляется в памяти.
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
    """Дописать в существующий проект людей, термины и замены из поиска проектов. -> изменилось ли."""
    people, np_ = vocab.merge_people(prof.get("people", []), clean_list(item.get("people")))
    terms, nt = vocab.merge_terms(prof.get("terms", []), clean_list(item.get("terms"))[:25])
    reps, nr = vocab.merge_replacements(prof.get("replacements", []), item.get("replacements") or [])
    prof.update(people=people, terms=terms, replacements=reps)
    return bool(np_ or nt or nr)


def from_found(slug: str, item: dict) -> dict:
    """Новый проект из ответа поиска проектов."""
    reps, _ = vocab.merge_replacements([], item.get("replacements") or [])
    return {"title": item.get("title") or slug, "context": str(item.get("context", "")),
            "people": vocab.merge_people([], clean_list(item.get("people")))[0],
            "terms": vocab.merge_terms([], clean_list(item.get("terms")))[0][:25],
            "replacements": reps}


def clean_list(value) -> list:
    return [str(x) for x in (value or []) if x] if isinstance(value, list) else []
