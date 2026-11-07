#!/usr/bin/env python3
"""Fictional projects and calls matching the Claude Design boards (Main, CallsTranscript, CallsNoAudio and
the rest), so the app's screens can be compared with the designs 1:1. No real clients.

  tools/demo_data.py [<dir>] [--today YYYY-MM-DD] [--no-audio]
      ->  <dir>/engine (profiles, .env, voices) and <dir>/Calls (calls); <dir> defaults to build/demo

Dates are relative to today, so the sidebar groups read "Вчера", then two and three days ago, as in the
designs (drawn on 2026-11-06: "Вчера" = 5 ноября, then 4 and 3 ноября 2026 г.). `--today 2026-11-06`
pins them to the designs' dates on any day.

Audio: billing webhooks gets real speech (macOS `say` placed at the transcript times, padded to 22:43,
encoded with ffmpeg) when `say` and `ffmpeg` are available; other calls get placeholder tracks of the right
size. `--no-audio` skips the speech.

Run the app on it:
  build/Demo.app/Contents/MacOS/Sozvon -engineDir <dir>/engine -callsDir <dir>/Calls ...
or
  defaults write io.github.able1991.sozvon engineDir <dir>/engine
  defaults write io.github.able1991.sozvon callsDir  <dir>/Calls

Project dot colors in the designs: Northwind blue, Acme purple, Студия «Луч» teal (tokens project-blue,
project-purple, project-teal). The app derives the color from the name, see projectColor in CallsView.swift.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

args = [a for a in sys.argv[1:] if not a.startswith("--")]
today = date.today()
if "--today" in sys.argv:
    today = date.fromisoformat(sys.argv[sys.argv.index("--today") + 1])
    args = [a for a in args if a != sys.argv[sys.argv.index("--today") + 1]]
with_audio = "--no-audio" not in sys.argv

root = Path(args[0] if args else "build/demo").resolve()
eng, calls = root / "engine", root / "Calls"
shutil.rmtree(calls, ignore_errors=True)
shutil.rmtree(eng / "voices", ignore_errors=True)
(eng / "profiles").mkdir(parents=True, exist_ok=True)
(eng / "voices").mkdir(parents=True, exist_ok=True)
calls.mkdir(parents=True, exist_ok=True)
(eng / ".env").write_text("CALL_ME_NAME=Аня\nSOZVON_LLM=claude\nSOZVON_LANGUAGE=ru,en\nSOZVON_MODEL=turbo\n")

ME = "Аня"

PROFILES = {
    "acme": {"title": "Acme", "context": "Мобильное приложение доставки: спринты, релизы, подрядчики.",
             "people": ["Иван Петров", "Мария Соколова", "Олег"], "terms": ["TestFlight", "релиз-кандидат", "спринт", "API"]},
    "northwind": {"title": "Northwind", "context": "Партнёрская интеграция и биллинг.",
                  "people": ["Sarah Miller", "Tom Baker"], "terms": ["webhook", "invoice.paid", "HMAC", "X-Signature", "sandbox"]},
    "studio": {"title": "Студия «Луч»", "context": "Съёмка для каталога и новый сайт.",
               "people": ["Екатерина Лебедева"], "terms": ["каталог", "лукбук", "ретушь"]},
}
for p in (eng / "profiles").glob("*.json"):
    p.unlink()
for slug, p in PROFILES.items():
    (eng / "profiles" / f"{slug}.json").write_text(
        json.dumps({"schema": 1, **p, "replacements": []}, ensure_ascii=False, indent=2))


def day(n):
    """n days before today."""
    return today - timedelta(days=n)


def utc(d, hh, mm, ss=0):
    """Local wall time on day d as ISO 8601 UTC."""
    local = datetime.combine(d, time(hh, mm, ss)).astimezone()
    return local.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp(sec):
    return f"{sec // 60:02d}:{sec % 60:02d}"


# ---------------------------------------------------------------- billing webhooks (Main, CallsTranscript)

BILLING_SUMMARY = """## Коротко
Договорились о схеме вебхуков для счетов: Northwind отправляет события с подписью в заголовке, повтор при ошибке до трёх раз с паузой. Ключи для песочницы придут в пятницу, боевые после приёмки.

## Решения
- Подпись запроса: HMAC в заголовке `X-Signature`, ключ выдаёт Northwind.
- Повторы: 3 попытки, пауза 30 с, 5 мин, 30 мин.
- Событие invoice.paid уходит один раз, дубли режем по id.

## Задачи
- [ ] Sarah: Прислать ключи для песочницы, пятница
- [ ] Tom: Описать формат событий в документации
- [ ] Аня: Проверить повторы на тестовом стенде"""

# (seconds, speaker, text); the 1:42 line is marked important (star).
BILLING_LINES = [
    (3, ME, "Привет, Sarah. Давай пройдёмся по вебхукам для счетов, у нас было три открытых вопроса."),
    (9, "Sarah Miller", "Sure. We need a retry policy and a signature header, and I want to agree on the event names before the sandbox keys go out."),
    (31, ME, "По подписи предлагаю HMAC в заголовке, ключ выдаёте вы. Повторы: три попытки с растущей паузой."),
    (58, "Tom Baker", "Works for me. Thirty seconds, five minutes, thirty minutes. After that we flag it on our side."),
    (102, ME, "Договорились: ключи для песочницы в пятницу, боевые после приёмки."),
    (135, "Sarah Miller", "One more thing: invoice.paid must be sent exactly once. If you retry, we dedupe by id, so keep the id stable."),
    (194, ME, "Да, id не меняем между повторами. Tom, опишешь формат событий в документации к среде?"),
    (220, "Tom Baker", "Yes, I'll have a draft by Wednesday and share the link in the thread."),
    (242, ME, "Отлично. Тогда последнее: лимит на размер события."),
]
BILLING_MARKS = [102.0]
BILLING_SECONDS = 22 * 60 + 43
BILLING_NOTES = [
    {"id": "4f6c2d1e-8a3b-4c5d-9e7f-0a1b2c3d4e51", "at": utc(day(1), 16, 2),
     "text": "Спросить у Sarah про лимит на размер события, в прошлом проекте упирались в 64 КБ.", "source": "app"},
    {"id": "4f6c2d1e-8a3b-4c5d-9e7f-0a1b2c3d4e52", "at": utc(day(1), 16, 5),
     "text": "Боевые ключи только после приёмки, не раньше. Напомнить Tom.", "source": "claude-code"},
]

# ---------------------------------------------------------------- the other calls (sidebar of every Calls board)

SPRINT_SUMMARY = """## Коротко
Спланировали спринт: API заказов, экран профиля и починка push-уведомлений. Олег берёт API, Иван экран профиля.

## Решения
- Спринт две недели, демо в пятницу.
- Push-уведомления чиним до новых фич.

## Задачи
- [ ] Олег: API заказов, среда
- [ ] Иван Петров: Экран профиля, пятница"""
SPRINT_LINES = [
    (4, ME, "Начнём. Что берём в спринт?"),
    (11, "Олег", "Предлагаю API заказов и экран профиля, и сначала починить push-уведомления."),
    (27, "Иван Петров", "Экран профиля мой, к пятнице успею."),
]

PHOTO_SUMMARY = """## Коротко
Обсудили съёмку для каталога: 40 образов, два дня в студии, ретушь за неделю.

## Задачи
- [ ] Екатерина Лебедева: Список образов, вторник"""
PHOTO_LINES = [
    (5, "Екатерина Лебедева", "Предлагаю снимать два дня: первый день одежда, второй аксессуары."),
    (19, ME, "Подходит. Ретушь успеете за неделю?"),
]

CONTRACT_SUMMARY = """## Коротко
Прошлись по договору с подрядчиком: сроки этапов, приёмка и штрафы за просрочку.

## Решения
- Оплата по этапам, 30% аванс.

## Задачи
- [ ] Мария Соколова: Правки юриста в договор, понедельник"""
CONTRACT_LINES = [
    (6, "Мария Соколова", "Юрист просит добавить приёмку по каждому этапу."),
    (21, ME, "Согласна, и аванс не больше тридцати процентов."),
]

ONBOARD_SUMMARY = """## Summary
Walked Sarah through the API sandbox and the billing dashboard.

## Action Items
- [ ] Sarah: Share the test account list"""
ONBOARD_LINES = [
    (3, ME, "Sarah, welcome! Let me show you the sandbox first."),
    (12, "Sarah Miller", "Great, I mostly need the billing endpoints."),
]

RETRO_SUMMARY = """## Коротко
Ретро по релизу 2.4: релиз прошёл без откатов, но тестирование заняло на два дня больше плана.

## Решения
- Релиз-кандидат собираем в понедельник, а не в среду.

## Задачи
- [ ] Иван Петров: Чек-лист регресса в TestFlight"""
RETRO_LINES = [
    (5, ME, "Что прошло хорошо в релизе 2.4?"),
    (13, "Иван Петров", "Без откатов, но регресс занял на два дня больше."),
    (30, "Олег", "Давайте собирать релиз-кандидат в понедельник."),
]

# (days ago, hh, mm, profile, topic, names, seconds, languages, status, summary, lines, extra call.json)
CALLS = [
    (1, 15, 30, "northwind", "billing webhooks", ["Sarah Miller", "Tom Baker"], BILLING_SECONDS, "ru,en", "done",
     BILLING_SUMMARY, BILLING_LINES, {"marks": BILLING_MARKS, "notes": BILLING_NOTES}),
    (1, 11, 0, "acme", "планирование спринта", ["Олег", "Иван Петров"], 48 * 60 + 12, "ru", "done",
     SPRINT_SUMMARY, SPRINT_LINES, {}),
    # "Ждёт описания": recorded, the user chose "Later" in "What was the call about?".
    (1, 9, 12, "", "", [], 6 * 60 + 8, "", "recorded", None, None, {"info_pending": True}),
    (2, 17, 45, "studio", "съёмка для каталога", ["Екатерина Лебедева"], 31 * 60 + 4, "ru", "done",
     PHOTO_SUMMARY, PHOTO_LINES, {}),
    (2, 14, 5, "acme", "договор с подрядчиком", ["Мария Соколова"], 65 * 60 + 20, "ru", "done",
     CONTRACT_SUMMARY, CONTRACT_LINES, {}),
    (2, 10, 30, "northwind", "онбординг Sarah", ["Sarah Miller"], 14 * 60 + 2, "en", "done",
     ONBOARD_SUMMARY, ONBOARD_LINES, {}),
    (3, 16, 0, "acme", "ретро по релизу", ["Иван Петров", "Олег"], 52 * 60 + 30, "ru", "done",
     RETRO_SUMMARY, RETRO_LINES, {}),
    # "Без расшифровки": recorded, never transcribed ("Don't Transcribe").
    (3, 12, 20, "", "созвон с бухгалтерией", [], 9 * 60 + 15, "ru", "recorded", None, None, {}),
]


def speech_tracks(d: Path, lines, seconds):
    """mic.m4a (the user's lines) and system.m4a (everyone else) with `say` speech at the transcript times."""
    if not (shutil.which("say") and shutil.which("ffmpeg")):
        return False
    with tempfile.TemporaryDirectory() as tmp:
        parts = {"mic": [], "sys": []}
        for i, (sec, who, text) in enumerate(lines):
            voice = ("Milena" if who == ME else "Samantha" if who == "Sarah Miller" else "Daniel")
            aiff = Path(tmp) / f"{i}.aiff"
            r = subprocess.run(["say", "-v", voice, "-o", str(aiff), text], capture_output=True)
            if r.returncode != 0:
                r = subprocess.run(["say", "-o", str(aiff), text], capture_output=True)
                if r.returncode != 0:
                    return False
            parts["mic" if who == ME else "sys"].append((sec, aiff))
        for track, out in (("mic", "mic.m4a"), ("sys", "system.m4a")):
            items = parts[track]
            cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-t", str(seconds),
                   "-i", "anullsrc=r=22050:cl=mono"]
            for _, f in items:
                cmd += ["-i", str(f)]
            chains = [f"[{k + 1}:a]aresample=22050,aformat=channel_layouts=mono,adelay={sec * 1000}[a{k}]"
                      for k, (sec, _) in enumerate(items)]
            mix = "[0:a]" + "".join(f"[a{k}]" for k in range(len(items)))
            chains.append(f"{mix}amix=inputs={len(items) + 1}:duration=first:normalize=0[out]")
            cmd += ["-filter_complex", ";".join(chains), "-map", "[out]", "-c:a", "aac", "-b:a", "32k",
                    str(d / out)]
            if subprocess.run(cmd, capture_output=True).returncode != 0:
                return False
    return True


for ago, hh, mm, profile, topic, names, secs, lang, status, summary, lines, extra in CALLS:
    d0 = day(ago)
    cid = f"{d0.isoformat()} {hh:02d}-{mm:02d}"
    title = PROFILES[profile]["title"] if profile else ""
    name = " · ".join(x for x in [cid, title, topic, ", ".join(names)] if x)
    d = calls / name
    d.mkdir()
    real = with_audio and lines is BILLING_LINES and speech_tracks(d, lines, secs)
    if not real:
        # Placeholder tracks of the right size, so the size is shown.
        (d / "mic.m4a").write_bytes(b"\0" * (secs * 8000))
        (d / "system.m4a").write_bytes(b"\0" * (secs * 9000))
    call = {"schema": 1, "id": cid, "created_at": utc(d0, hh, mm), "status": status,
            "audio": {"mic_start": 0.0, "system_start": 0.0, "mic_seconds": float(secs), "system_seconds": float(secs)},
            "profile": profile, "names": names, "topic": topic, "terms": "", "languages": lang,
            "summary": summary is not None}
    if status == "done":
        call["engine"] = {"version": "demo", "model": "turbo"}
    call.update(extra)
    (d / "call.json").write_text(json.dumps(call, ensure_ascii=False, indent=2))
    if summary:
        (d / "summary.md").write_text(summary + "\n")
    if lines:
        marked = {i for i, (s, _, _) in enumerate(lines) if s in {int(m) for m in extra.get("marks", [])}}
        people = list(dict.fromkeys(w for _, w, _ in lines))
        head = f"# Звонок {cid}" + (f" · {title}" if title else "") + (f" · {topic}" if topic else "")
        md = [head, "", f"Длительность: {stamp(secs)} · Участники: {', '.join(people)}", ""]
        if summary:
            md += [summary, "", "---", "", "## Расшифровка", ""]
        md += [f"**[{stamp(s)}] {w}:** {x}{' ⭐' if i in marked else ''}\n" for i, (s, w, x) in enumerate(lines)]
        (d / "transcript.txt").write_text("\n".join(f"[{stamp(s)}] {w}: {x}" for s, w, x in lines) + "\n")
        # Written last: newer than summary.md, as after a transcript edit ("Саммари устарело").
        (d / "transcript.md").write_text("\n".join(md))

# Voice prints: the user's own (Аня) and Sarah Miller saved; Tom Baker is not, so billing webhooks asks
# "Подписи верные?". Schema: docs/CONTRACT.md section 6 (the embedding is a placeholder).
VOICES = [
    {"id": "a1b2c3d4e5f60718293a4b5c6d7e8f90", "name": ME, "profile": "", "me": True, "seconds": 48.0,
     "updated_at": utc(day(0), 9, 0)},
    {"id": "0f1e2d3c4b5a69788796a5b4c3d2e1f0", "name": "Sarah Miller", "profile": "", "me": False, "seconds": 36.5,
     "updated_at": utc(day(2), 10, 50)},
]
for v in VOICES:
    f = eng / "voices" / f"{v['id']}.json"
    f.write_text(json.dumps({"schema": 1, **v, "embedding": [0.0] * 256}, ensure_ascii=False))
    os.chmod(f, 0o600)

print(root)
