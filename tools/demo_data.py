#!/usr/bin/env python3
"""Вымышленные проекты и звонки для скриншотов README и лендинга (никаких реальных клиентов).

  tools/demo_data.py <папка>   ->  <папка>/engine (профили, .env) и <папка>/Calls (звонки)
Потом:
  defaults write io.github.able1991.sozvon engineDir <папка>/engine
  defaults write io.github.able1991.sozvon callsDir  <папка>/Calls
"""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else "build/demo").resolve()
eng, calls = root / "engine", root / "Calls"
(eng / "profiles").mkdir(parents=True, exist_ok=True)
calls.mkdir(parents=True, exist_ok=True)
(eng / ".env").write_text("CALL_ME_NAME=Аня\nSOZVON_LLM=claude\nSOZVON_LANGUAGE=ru,en\nSOZVON_MODEL=turbo\n")

PROFILES = {
    "acme": {"title": "Acme", "context": "Запуск мобильного приложения доставки.",
             "people": ["Иван Петров", "Мария Соколова", "Олег"], "terms": ["TestFlight", "релиз-кандидат", "push-уведомления", "Firebase", "API"]},
    "northwind": {"title": "Northwind", "context": "Партнёрская интеграция и биллинг.",
                  "people": ["Sarah Miller", "Tom Baker"], "terms": ["webhook", "invoice", "SLA", "sandbox"]},
    "studio": {"title": "Студия «Луч»", "context": "Ребрендинг и новый сайт.",
               "people": ["Екатерина Лебедева"], "terms": ["логотип", "гайдлайн", "Figma", "лендинг"]},
}
for slug, p in PROFILES.items():
    (eng / "profiles" / f"{slug}.json").write_text(json.dumps({**p, "replacements": []}, ensure_ascii=False, indent=2))

SUMMARY_ACME = """## Коротко
Обсудили выпуск версии 2.4. Иван закрыл последние баги, Мария подтвердила тексты push-уведомлений. Релиз-кандидат уходит в TestFlight в среду.

## Решения
- Релиз 2.4 в App Store в понедельник, если в TestFlight за два дня не будет критичных багов.
- Push-уведомления о статусе заказа включаем всем, о скидках только по согласию.

## Задачи
- [ ] Иван: собрать релиз-кандидат и отправить в TestFlight, среда.
- [ ] Мария: финальные тексты push-уведомлений на английском, вторник.
- [ ] Аня: согласовать дату релиза с маркетингом.

## Открытые вопросы
- Нужен ли отдельный экран согласия на уведомления для старых пользователей."""

TRANSCRIPT_ACME = [
    ("00:04", "Аня", "Привет! Давайте пройдёмся по релизу 2.4. Иван, что с багами?"),
    ("00:11", "Иван Петров", "Последние два закрыл вчера, падение на экране оплаты больше не воспроизводится."),
    ("00:24", "Аня", "Отлично. Мария, тексты для push-уведомлений готовы?"),
    ("00:29", "Мария Соколова", "Русские готовы, английские пришлю во вторник. Про скидки предлагаю слать только тем, кто согласился."),
    ("00:47", "Аня", "Согласна. Тогда релиз-кандидат в среду в TestFlight, и если два дня тихо, в понедельник в App Store."),
    ("01:02", "Иван Петров", "Успею, соберу в среду утром."),
]

CALLS = [
    ("2026-11-05 11-00 · Acme · релиз 2.4 · Иван Петров, Мария Соколова, Олег +3", "acme", "релиз 2.4",
     ["Иван Петров", "Мария Соколова", "Олег", "Анна Крылова", "Дмитрий", "Света"], 1712, "ru", SUMMARY_ACME, TRANSCRIPT_ACME),
    ("2026-11-05 15-30 · Northwind · billing webhooks · Sarah Miller", "northwind", "billing webhooks",
     ["Sarah Miller"], 1395, "en",
     "## Summary\nAgreed on the webhook format for invoices. Sandbox access goes live on Friday.\n\n## Action Items\n- [ ] Tom: enable sandbox keys, Friday.\n- [ ] Аня: send the SLA draft.",
     [("00:03", "Аня", "Hi Sarah, shall we go through the invoice webhooks?"),
      ("00:09", "Sarah Miller", "Sure. We need a retry policy and a signature header.")]),
    ("2026-11-04 17-15 · Студия «Луч» · новый логотип · Екатерина Лебедева", "studio", "новый логотип",
     ["Екатерина Лебедева"], 2534, "ru",
     "## Коротко\nВыбрали второй вариант логотипа, гайдлайн будет к концу месяца.\n\n## Задачи\n- [ ] Екатерина: гайдлайн в Figma.",
     [("00:05", "Екатерина Лебедева", "Показываю три варианта логотипа, второй мой любимый.")]),
    ("2026-11-04 10-00 · Acme · планирование спринта · Олег", "acme", "планирование спринта",
     ["Олег"], 1980, "ru", "## Коротко\nСпланировали спринт: API заказов и экран профиля.",
     [("00:02", "Олег", "В спринт берём API заказов и профиль.")]),
    ("2026-11-03 18-40", "", "", [], 845, "ru", None, None),
]

for name, profile, topic, names, secs, lang, summary, transcript in CALLS:
    d = calls / name
    d.mkdir(exist_ok=True)
    (d / "meta.json").write_text(json.dumps({"mic_seconds": secs, "system_seconds": secs}))
    # Пустые дорожки нужного размера для отображения объёма.
    (d / "mic.m4a").write_bytes(b"\0" * (secs * 8000))
    (d / "system.m4a").write_bytes(b"\0" * (secs * 9000))
    if profile or names:
        (d / "call.json").write_text(json.dumps({"profile": profile, "names": names, "topic": topic,
                                                 "terms": "", "languages": lang}, ensure_ascii=False))
    if summary:
        (d / "summary.md").write_text(summary + "\n")
    if transcript:
        body = "\n".join(f"**[{t}] {w}:** {x}\n" for t, w, x in transcript)
        (d / "transcript.md").write_text(f"# Звонок {name[:16]}\n\n{summary}\n\n---\n\n## Расшифровка\n\n{body}")
        (d / "transcript.txt").write_text("\n".join(f"[{t}] {w}: {x}" for t, w, x in transcript) + "\n")

print(root)
