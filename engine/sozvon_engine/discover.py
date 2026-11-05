"""Найти проекты через Claude Code (или Codex CLI) и сделать из них профили Sozvon.

Claude смотрит локальные сессии Claude Code (~/.claude/projects: названия папок,
CLAUDE.md, память) и, если может, спрашивает активные сессии, о чём там работа.
Возвращает JSON со списком проектов; этот скрипт пишет их в profiles/.
Существующие профили не перезаписываются: в них только дописываются новые
люди и термины.

Текст, который Claude прочитает, уходит в Anthropic, как и при саммари.
Инструменты у Claude только на чтение (Read, Glob, Grep) плюс ListAgents и
SendMessage для вопросов другим сессиям.
"""
import json
import re
import sys
from pathlib import Path

from . import llm, profiles
from .i18n import t

PROMPT = """Ты помогаешь настроить Sozvon, локальную расшифровку рабочих созвонов.
Нужно составить список проектов пользователя, чтобы Whisper правильно писал
имена людей, названия и термины.

Где искать. Только внутри ~/.claude, никаких других папок: пользователь не
давал доступа к своим документам, и macOS будет спрашивать разрешения.
1. ~/.claude/projects: каждая папка это рабочая директория (слэши заменены на «-»),
   по названию понятен проект. Внутри memory/*.md бывают заметки, их можно читать.
   Логи сессий (*.jsonl) целиком не читай, максимум Grep по именам.
2. Главное: если доступен ListAgents, посмотри активные сессии и коротко спроси у
   каждой через SendMessage: «Для настройки расшифровки созвонов: какой это
   проект/клиент, с кем по нему созваниваемся (имена, роли), какие термины и
   названия звучат на созвонах? Ответь коротко, без паролей и сумм.»
   ВАЖНО: ответы приходят тебе входящими сообщениями от других сессий, но только между
   твоими вызовами инструментов. Если сразу закончить, ответы потеряются. Поэтому после
   вопросов разбирай заметки папок (Read/Grep), а перед финальным ответом ещё 3 или 4 раза
   вызови ListAgents, чтобы успели дойти ответы (всего не дольше 3 минут). Ответы сессий
   важнее догадок по названиям папок: бери из них людей, термины и ослышки.

Не включай пароли, токены, ключи, суммы денег, личные данные кроме имён и ролей.
Не включай в people самого пользователя (того, кто ведёт эти сессии): он и так есть на каждом звонке.
Пропусти служебные и учебные папки без реального проекта и саму разработку Sozvon.

Ответ строго один JSON-массив, без текста вокруг:
[{"slug": "латиница-без-пробелов", "title": "Название", "context": "1-2 предложения о чём созвоны",
  "people": ["Имя Фамилия"], "terms": ["до 25 терминов, самые характерные первыми"],
  "replacements": [["как Whisper может ослышаться", "как правильно"]]}]
replacements только если их назвала сессия или они очевидны («акме груп» -> «Acme Group»);
не добавляй замены обычных слов русского языка.
"""


CODEX_EXTRA = """
У тебя нет ListAgents/SendMessage: вместо вопросов живым сессиям посмотри
~/.codex/sessions (там JSONL прошлых сессий Codex: в начале каждой cwd и первые
сообщения) и ~/.claude/projects, если есть. Только эти две папки. Читай выборочно.
"""


def status(text: str):
    """Строка прогресса для окна приложения: STATUS: …"""
    print(f"STATUS: {text}", flush=True)


def describe(tool: str, inp: dict, state: dict) -> str:
    """Шаг агента -> понятная строка прогресса."""
    if tool == "ListAgents":
        return t("discover_agents")
    if tool == "SendMessage":
        state["asked"] += 1
        who = str(inp.get("to", "")).split(" [")[0].split("/")[-1].replace(".sock", "") or "?"
        return t("discover_ask", who=who[:40], n=state["asked"])
    if tool == "Read":
        state["read"] += 1
        path = Path(str(inp.get("file_path", "")))
        parts = path.parts
        proj = next((parts[i + 1] for i, x in enumerate(parts) if x == "projects" and i + 1 < len(parts)), path.name)
        what = proj.split("-")[-1] or proj
        return t("discover_read", what=what[:40], n=state["read"])
    return t("discover_search")


def project_dirs() -> list:
    """Папки ~/.claude/projects с понятным путём и подсказками (заметки памяти).

    Имя папки это рабочая директория со слэшами, заменёнными на «-»: «-Users-anna-Projects-acme».
    Даём Claude полный список, чтобы ни одна папка (вроде Projects/acme) не потерялась.
    """
    root = Path.home() / ".claude" / "projects"
    home = str(Path.home()).replace("/", "-")
    out = []
    for d in sorted(root.iterdir()) if root.is_dir() else []:
        if not d.is_dir():
            continue
        rel = d.name[len(home):] if d.name.startswith(home) else d.name
        rel = rel.lstrip("-").replace("-", "/")
        sessions = len(list(d.glob("*.jsonl")))
        mem = sorted(x.stem for x in (d / "memory").glob("*.md") if x.stem != "MEMORY") if (d / "memory").is_dir() else []
        out.append((d.name, rel, sessions, mem[:8]))
    return out


def dirs_block() -> str:
    lines = []
    for name, rel, n, mem in project_dirs():
        hint = f"; заметки: {', '.join(mem)}" if mem else ""
        lines.append(f"- ~/{rel} (папка {name}, сессий {n}{hint})")
    return "\n".join(lines)


def parse_items(text: str):
    """Найти в ответе первый JSON-массив объектов (модель может писать текст до и после)."""
    dec = json.JSONDecoder()
    for i, ch in enumerate(text):
        if ch != "[":
            continue
        try:
            val, _ = dec.raw_decode(text, i)
        except json.JSONDecodeError:
            continue
        if isinstance(val, list) and val and all(isinstance(x, dict) for x in val):
            return val
    return None


def _words(title: str) -> set:
    """Значимые слова названия: «Acme (Акме Груп)» -> {acme, акме, груп}; короткие и общие отброшены."""
    stop = {"ru", "com", "io", "the", "and", "saas", "проект"}
    return {w for w in re.findall(r"[\w]+", str(title).lower()) if len(w) > 3 and w not in stop}


def apply_projects(items: list, root: Path | None = None) -> tuple:
    """Записать найденные проекты: новые создать, в существующие дописать людей, термины, замены.

    root: папка проектов (по умолчанию profiles/ в папке данных).
    -> (созданные названия, дополненные названия).
    """
    from . import jsonfile
    root = Path(root or profiles.root())
    root.mkdir(parents=True, exist_ok=True)
    existing = {}
    for f in root.glob("*.json"):
        data = jsonfile.read(f)
        if data is not None and profiles.valid_slug(f.stem):
            existing[f] = _words(data.get("title", "")) | {f.stem}
    created, updated = [], []
    for it in items:
        if not isinstance(it, dict):
            continue
        slug = profiles.to_slug(it.get("slug", ""))
        if not slug:
            continue
        f = root / f"{slug}.json"
        if not f.exists():
            # Тот же проект под другим slug («acmegroup» и «acme»): совпадение по словам названия.
            words = _words(it.get("title", "")) | {slug}
            same = [g for g, w in existing.items() if w & words]
            if same:
                f = same[0]
        with jsonfile.locked(f):
            if f.exists():
                prof = jsonfile.read(f, default={}) or {}
                if profiles.merge_found(prof, it):
                    jsonfile.write_atomic(f, jsonfile.with_schema(prof))
                    updated.append(prof.get("title", slug))
            else:
                prof = profiles.from_found(slug, it)
                jsonfile.write_atomic(f, jsonfile.with_schema(prof))
                existing[f] = _words(prof["title"]) | {slug}
                created.append(prof["title"])
    return created, updated


def main() -> int:
    name, _ = llm.backend()
    if not name:
        print(t("discover_no_cli"), file=sys.stderr)
        return 1
    prompt = PROMPT + (CODEX_EXTRA if name == "codex" else "") + (
        "\nВсе рабочие папки из ~/.claude/projects (разбери КАЖДУЮ: это проект клиента или нет; "
        "путь вроде Projects/acme/app тоже может быть проектом, смотри заметки и сессии):\n" + dirs_block() + "\n")
    # Рабочая папка: служебная папка CLI, не домашняя. Иначе CLI заглядывает в ~/Documents,
    # ~/Desktop и т.п., и macOS спрашивает у Sozvon доступ к ним.
    cwd = Path.home() / (".claude" if name == "claude" else ".codex")
    cwd.mkdir(exist_ok=True)
    state = {"asked": 0, "read": 0}

    def on_event(tool, inp):
        status(describe(tool, inp, state))

    status(t("discover_start", name=name))
    out, _, err = llm.run(prompt, cwd, agentic=True, timeout=1200,
                          on_event=on_event if name == "claude" else None)
    status(t("discover_done"))
    if not out:
        print(t("discover_failed", err=err), file=sys.stderr)
        return 1
    root = profiles.root()
    root.mkdir(parents=True, exist_ok=True)
    (root / ".discover-last.txt").write_text(out, encoding="utf-8")
    items = parse_items(out)
    if items is None:
        print(t("discover_no_list", out=out[:500]), file=sys.stderr)
        return 1
    created, updated = apply_projects(items, root)
    msg = t("discover_new", n=len(created)) + (f" ({', '.join(created)})" if created else "")
    if updated:
        msg += t("discover_updated", n=len(updated))
    print(msg)
    return 0
