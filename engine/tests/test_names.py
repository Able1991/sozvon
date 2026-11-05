"""Имена собеседников по смыслу и язык саммари."""
from sozvon_engine import llm
from sozvon_engine.pipeline import names, summary


def paras():
    return [(0, 2, "Маша, как у тебя с тестами?", "Я"),
            (2, 5, "Я всё проверила, багов нет.", "Собеседник 1"),
            (5, 7, "Саша, а деплой?", "Я"),
            (7, 9, "Завтра выкатим.", "Собеседник 2")]


def test_resolve_names_applies_mapping(monkeypatch, tmp_path):
    seen = {}

    def fake(prompt, cwd, **kw):
        seen["p"] = prompt
        return ('Вот: {"Собеседник 1": "Мария Толкачёва", "Собеседник 2": "Александр Пантелеев"}', "claude", "")
    monkeypatch.setattr(llm, "run", fake)
    out = names.resolve_names(paras(), ["Александр Пантелеев", "Мария Толкачёва"], ["Александр Пантелеев"], "Я", tmp_path)
    assert [w for *_, w in out] == ["Я", "Мария Толкачёва", "Я", "Александр Пантелеев"]
    assert "Собеседник 1, Собеседник 2" in seen["p"] and "Точно были на звонке: Александр Пантелеев" in seen["p"]


def test_resolve_names_keeps_generic_when_unsure(monkeypatch, tmp_path):
    monkeypatch.setattr(llm, "run", lambda p, c, **kw: ('{"Собеседник 1": null, "Собеседник 2": "Я"}', "claude", ""))
    out = names.resolve_names(paras(), ["Анна"], [], "Я", tmp_path)
    assert [w for *_, w in out][1::2] == ["Собеседник 1", "Собеседник 2"]


def test_resolve_names_no_duplicates(monkeypatch, tmp_path):
    monkeypatch.setattr(llm, "run", lambda p, c, **kw: ('{"Собеседник 1": "Анна", "Собеседник 2": "Анна"}', "claude", ""))
    out = names.resolve_names(paras(), ["Анна"], [], "Я", tmp_path)
    assert [w for *_, w in out][1::2] == ["Анна", "Собеседник 2"]


def test_resolve_names_falls_back_to_order(monkeypatch, tmp_path):
    monkeypatch.setattr(llm, "run", lambda p, c, **kw: (None, "claude", "boom"))
    out = names.resolve_names(paras(), ["Анна", "Олег"], ["Анна"], "Я", tmp_path)
    assert [w for *_, w in out][1::2] == ["Анна", "Собеседник 2"]


def test_resolve_names_not_json(monkeypatch, tmp_path):
    monkeypatch.setattr(llm, "run", lambda p, c, **kw: ("не знаю", "claude", ""))
    out = names.resolve_names(paras(), ["Анна"], ["Анна"], "Я", tmp_path)
    assert [w for *_, w in out][1::2] == ["Анна", "Собеседник 2"]


def test_english_ui_labels_and_prompt(monkeypatch, tmp_path):
    monkeypatch.setenv("SOZVON_UI_LANG", "en")
    seen = {}
    monkeypatch.setattr(llm, "run", lambda p, c, **kw: (seen.setdefault("p", p) and '{"Speaker 1": "Ann"}', "claude", ""))
    p = [(0, 2, "Hi Ann", "Me"), (2, 4, "Hi", "Speaker 1")]
    out = names.resolve_names(p, ["Ann"], [], "Me", tmp_path)
    assert out[1][3] == "Ann" and "Speaker 1" in seen["p"] and "JSON object only" in seen["p"]


def test_summary_follows_call_language_not_ui(monkeypatch, tmp_path):
    seen = {}
    monkeypatch.setattr(llm, "run", lambda prompt, cwd, **kw: (seen.setdefault("p", prompt), "claude", ""))
    monkeypatch.setenv("SOZVON_UI_LANG", "en")
    summary.summarize("[00:00] Я: привет", "Я", tmp_path, "", "ru")
    assert "саммари на русском" in seen["p"]
    seen.clear()
    summary.summarize("[00:00] Ich: hallo", "Ich", tmp_path, "", "de")
    assert "summary in German" in seen["p"]
