"""JSON reads and atomic writes: a temp file in the same folder plus os.replace.

The app, the MCP server and the engine never see a half-written file.
Read-modify-write runs under locked(): otherwise two processes (MCP server and
transcription) read the same version and the second overwrites the first one's change.
"""
import json
import os
import tempfile
from contextlib import contextmanager
from pathlib import Path

from . import platform_support

SCHEMA = 1


class JsonFileError(ValueError):
    """The file exists but is not a JSON object."""


def read(path: Path, default=None, strict: bool = False):
    """JSON object from a file. Missing file: default. Broken file: default or JsonFileError (strict)."""
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


def _ensure_parent(path: Path) -> None:
    """Create the file's folder only inside the engine data folder (profiles/, the index...).

    Anywhere else, a call folder above all, the folder must exist: a call the app just moved to the
    Trash must never come back as a folder with a lone call.json or call.json.lock (FileNotFoundError).
    """
    parent = path.parent
    if parent.is_dir():
        return
    from . import paths
    try:
        inside = parent.resolve().is_relative_to(paths.data_dir().resolve())
    except OSError:
        inside = False
    if not inside:
        raise FileNotFoundError(f"{parent}: no such folder")
    parent.mkdir(parents=True, exist_ok=True)


@contextmanager
def locked(path: Path):
    """Exclusive lock for the duration of an edit: flock on a sibling <file>.lock.

    A separate file is locked, not the JSON itself: write_atomic replaces the JSON with a new inode.
    The lock is released even if the process crashes (it is held by an open descriptor).
    The folder is created only inside the data folder (see _ensure_parent): for a call folder that is
    gone this raises FileNotFoundError instead of bringing the folder back.
    """
    path = Path(path)
    _ensure_parent(path)
    fd = os.open(path.with_name(path.name + ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        platform_support.lock_exclusive(fd)
        yield
    finally:
        platform_support.unlock(fd)
        os.close(fd)


def write_atomic(path: Path, data: dict) -> None:
    """Write the whole JSON or nothing at all. A missing folder outside the data folder: FileNotFoundError."""
    path = Path(path)
    _ensure_parent(path)
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
    """Copy with "schema": 1 as the first key (easier to read by eye)."""
    return {"schema": SCHEMA, **{k: v for k, v in data.items() if k != "schema"}}
