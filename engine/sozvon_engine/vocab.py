"""Общий словарь vocab.json и правила слияния терминов, замен и людей.

Одно место для правил: ими пользуются общий словарь, проекты (profiles.py), MCP-инструменты
и поиск проектов. Сравнение без учёта регистра.
"""
from contextlib import contextmanager
from pathlib import Path

from . import jsonfile, paths


def _key(s: str) -> str:
    return str(s).strip().casefold()


def valid_pair(pair) -> bool:
    return isinstance(pair, (list, tuple)) and len(pair) == 2 and bool(pair[0]) and bool(pair[1])


def merge_terms(existing: list, new: list, front: bool = False) -> tuple[list, list]:
    """Добавить новые термины без повторов. front: новые вперёд (выше приоритет в подсказке).

    -> (итоговый список, что реально добавлено).
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
    """Замена ослышки: та же левая часть заменяет правую. -> (итог, прежняя правая часть или None)."""
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
    """Добавить только замены с новой левой частью (поиск проектов не перетирает правки человека)."""
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
    """Люди из поиска проектов: точное совпадение имени без учёта регистра."""
    return merge_terms(existing, new)


def new_call_people(existing: list, names: list, me: str) -> list:
    """Кого из собеседников звонка ещё нет в проекте.

    Совпадение по имени: «Анна» уже есть, если в проекте «Анна Петрова». Себя не добавляем.
    """
    known = {_key(w) for p in existing for w in str(p).split()}
    out = []
    for n in names:
        n = n.strip()
        if n and _key(n) != _key(me) and _key(n.split()[0]) not in known:
            known.add(_key(n.split()[0]))
            out.append(n)
    return out


def all_replacements(vocab: dict, prof: dict) -> list:
    """Замены звонка: общие из vocab.json и замены проекта."""
    return [p for p in list(vocab.get("replacements", [])) + list(prof.get("replacements", [])) if valid_pair(p)]


# ---------- хранилище vocab.json ----------

def path() -> Path:
    return paths.engine_dir().vocab


def load() -> dict:
    """Читается при каждом вызове: правки применяются сразу."""
    return jsonfile.read(path(), default={}) or {}


def save(vocab: dict) -> None:
    jsonfile.write_atomic(path(), jsonfile.with_schema(vocab))


@contextmanager
def editing():
    """Правка vocab.json под блокировкой: свежая копия с диска, запись при выходе, если изменилась."""
    with jsonfile.locked(path()):
        vocab = load()
        before = jsonfile.with_schema(vocab)
        yield vocab
        if jsonfile.with_schema(vocab) != before:
            save(vocab)
