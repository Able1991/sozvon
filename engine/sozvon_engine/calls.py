"""Папки звонков и call.json (docs/CONTRACT.md, раздел 4).

Имя папки только для человека: «2026-11-04 15-01 · проект · тема · люди». id звонка это
call.json["id"] или первые 16 символов имени папки; после переименования он не меняется.
Запись call.json атомарная, перед записью файл перечитывается: поля приложения не теряются.
"""
from dataclasses import dataclass, field
import re
from pathlib import Path

from . import jsonfile, paths

CALL_SCHEMA = 1
ID_LEN = 16
# id: дата начала записи, у второй записи в ту же минуту суффикс «-2», «-3»...
ID_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}(?:-\d+)?(?= |$)")
STATUSES = ("recorded", "processing", "done", "failed")


def call_file(d: Path) -> Path:
    return Path(d) / "call.json"


def read_call(d: Path, strict: bool = False) -> dict:
    """call.json звонка; нет файла: заготовка со схемой и id по имени папки.

    strict: битый файл даёт jsonfile.JsonFileError, а не пустую заготовку (движок не должен
    перезаписать испорченный файл приложения своим).
    """
    d = Path(d)
    c = jsonfile.read(call_file(d), default=None, strict=strict) or {}
    c.setdefault("schema", CALL_SCHEMA)
    if not isinstance(c.get("id"), str) or not c["id"]:
        c["id"] = id_from_name(d.name)
    return c


def id_from_name(name: str) -> str:
    """id по имени папки (запасной путь для папок без call.json)."""
    m = ID_RE.match(name)
    return m.group(0) if m else name[:ID_LEN]


def write_call(d: Path, call: dict) -> None:
    jsonfile.write_atomic(call_file(d), jsonfile.with_schema(call))


def update_call(d: Path, **fields) -> dict:
    """Перечитать call.json, обновить поля, записать атомарно. -> итоговый словарь."""
    call = read_call(d)
    call.update(fields)
    write_call(d, call)
    return call


def call_id(d: Path) -> str:
    """Постоянный id звонка (call.json id или id из имени папки)."""
    cid = (jsonfile.read(call_file(d), default={}) or {}).get("id")
    return cid if isinstance(cid, str) and cid else id_from_name(Path(d).name)


def audio_meta(d: Path, call: dict) -> dict:
    """Смещения дорожек: call.json["audio"] (схема 1), для старых записей meta.json."""
    meta = call.get("audio")
    if isinstance(meta, dict) and meta:
        return meta
    return jsonfile.read(Path(d) / "meta.json", default={}) or {}


def duration_seconds(d: Path, call: dict) -> float:
    meta = audio_meta(d, call)
    return max(float(meta.get("mic_seconds") or 0), float(meta.get("system_seconds") or 0))


def _safe_id(cid: str) -> bool:
    return (isinstance(cid, str) and cid.strip() != "" and "/" not in cid and "\\" not in cid
            and "\x00" not in cid and cid not in (".", "..") and not cid.startswith("."))


def find_call(cid: str, root: Path | None = None) -> Path:
    """Папка звонка по id (или по старому полному имени папки), только внутри папки звонков."""
    from . import i18n
    root = Path(root or paths.calls_dir()).resolve()
    if not _safe_id(cid) or not root.is_dir():
        raise ValueError(i18n.t("no_call", id=cid))
    for d in sorted(root.iterdir()):
        if not d.is_dir() or d.resolve().parent != root:
            continue
        if d.name == cid or call_id(d) == cid:
            return d
    raise ValueError(i18n.t("no_call", id=cid))


@dataclass
class CallInfo:
    id: str
    path: Path
    date: str
    topic: str = ""
    profile: str = ""
    people: list = field(default_factory=list)
    seconds: float = 0.0
    status: str = ""

    @property
    def has_summary(self) -> bool:
        return (self.path / "summary.md").exists()

    @property
    def has_transcript(self) -> bool:
        return (self.path / "transcript.txt").exists() or (self.path / "transcript.md").exists()

    def text(self) -> str:
        """Саммари и расшифровка для поиска (без учёта регистра)."""
        out = []
        for name in ("summary.md", "transcript.txt"):
            f = self.path / name
            if f.exists():
                out.append(f.read_text(encoding="utf-8", errors="replace"))
        return "\n".join(out)


def list_calls(root: Path | None = None) -> list:
    """Все звонки, новые первыми."""
    root = Path(root or paths.calls_dir())
    out = []
    if not root.is_dir():
        return out
    for d in sorted(root.iterdir(), key=lambda p: p.name, reverse=True):
        if not d.is_dir() or d.name.startswith("."):
            continue
        c = read_call(d)
        names = c.get("names") if isinstance(c.get("names"), list) else []
        out.append(CallInfo(id=c["id"], path=d, date=d.name[:ID_LEN], topic=str(c.get("topic") or ""),
                            profile=str(c.get("profile") or ""), people=[str(n) for n in names],
                            seconds=duration_seconds(d, c), status=str(c.get("status") or "")))
    return out
