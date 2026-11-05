"""Файлы расшифровки: чистые функции."""
from sozvon_engine.pipeline import render

PARAS = [(0, 4, "Привет. Как дела?", "Я"), (5, 65.4, "Хорошо.", "Анна")]


def test_format_timestamp():
    assert render.format_timestamp(0) == "00:00"
    assert render.format_timestamp(65.9) == "01:05"
    assert render.format_timestamp(3725) == "01:02:05"


def test_render_txt():
    assert render.render_txt(PARAS) == "[00:00] Я: Привет. Как дела?\n[00:05] Анна: Хорошо.\n"


def test_render_md_without_summary():
    md = render.render_md("2026-11-04 15-01", PARAS, "Acme", "запуск")
    lines = md.splitlines()
    assert lines[0] == "# Звонок 2026-11-04 15-01 · Acme · запуск"
    assert lines[2] == "Длительность: 01:05 · Участники: Я, Анна"
    assert "**[00:05] Анна:** Хорошо." in md and "## Расшифровка" not in md


def test_render_md_with_summary_english(monkeypatch):
    monkeypatch.setenv("SOZVON_UI_LANG", "en")
    md = render.render_md("2026-11-04 15-01", PARAS, summary="## Summary\nOk.")
    assert md.startswith("# Call 2026-11-04 15-01\n\nDuration: 01:05 · Participants: Я, Анна")
    assert md.index("## Summary") < md.index("## Transcript") < md.index("**[00:00] Я:**")


def test_people_in_order():
    assert render.people(PARAS + [(70, 71, "Ещё", "Я")]) == ["Я", "Анна"]
