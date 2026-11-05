"""Чтение и атомарная запись JSON: временный файл в той же папке и os.replace.

Так приложение, MCP-сервер и движок никогда не видят наполовину записанный файл.
Правка «прочитать, изменить, записать» идёт под locked(): иначе два процесса (MCP-сервер и
расшифровка) читают одну версию и второй затирает правку первого.
"""
import fcntl
import json
import os
import tempfile
from contextlib import contextmanager
from pathlib import Path

SCHEMA = 1


class JsonFileError(ValueError):
    """Файл есть, но это не JSON-объект."""


def read(path: Path, default=None, strict: bool = False):
    """JSON-объект из файла. Нет файла: default. Битый файл: default или JsonFileError (strict)."""
    path = Path(path)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default
    except (ValueError, UnicodeDecodeError) as e:
        if strict:
            raise JsonFileError(f"{path}: {e}") from e
        return default
    if not isinstance(data, dict):
        if strict:
            raise JsonFileError(f"{path}: ожидался JSON-объект")
        return default
    return data


@contextmanager
def locked(path: Path):
    """Исключительная блокировка файла на время правки: flock на соседнем <файл>.lock.

    Блокируется отдельный файл, а не сам JSON: write_atomic подменяет JSON новым inode.
    Блокировка снимается и при падении процесса (её держит открытый дескриптор).
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path.with_name(path.name + ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def write_atomic(path: Path, data: dict) -> None:
    """Записать JSON целиком или не записать вовсе."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def with_schema(data: dict) -> dict:
    """Копия с "schema": 1 первым ключом (так файл читается глазами)."""
    return {"schema": SCHEMA, **{k: v for k, v in data.items() if k != "schema"}}
