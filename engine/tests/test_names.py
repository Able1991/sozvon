"""Inferring participant names from context, and summary language."""
import json
from pathlib import Path

import pytest

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
        return ('Вот: {"Собеседник 1": "Мария Королёва", "Собеседник 2": "Александр Бородин"}', "claude", "")
    monkeypatch.setattr(llm, "run", fake)
    out = names.resolve_names(paras(), ["Александр Бородин", "Мария Королёва"], ["Александр Бородин"], "Я", tmp_path)
    assert [w for *_, w in out] == ["Я", "Мария Королёва", "Я", "Александр Бородин"]
    assert "Собеседник 1, Собеседник 2" in seen["p"] and "Точно были на звонке: Александр Бородин" in seen["p"]


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


FIXTURE = json.loads((Path(__file__).resolve().parents[2] / "Tests" / "Fixtures" / "participants.json")
                     .read_text(encoding="utf-8"))


@pytest.mark.parametrize("case", FIXTURE["participants"], ids=lambda c: c["note"])
def test_participants_shared_with_the_app(case):
    """The same cases as the app's CallParticipants.derived (Tests/Fixtures/participants.json)."""
    paras = [(i, i + 1, "x", w) for i, w in enumerate(case["speakers"])]
    assert names.participants(paras, case["me"], case["typed"]) == case["participants"]


def test_generic_labels_shared_with_the_app():
    g = FIXTURE["generic"]
    assert [n for n in g["yes"] if not names.is_generic(n, g["me"])] == []
    assert [n for n in g["no"] if names.is_generic(n, g["me"])] == []


def test_is_voice_counts_names_and_numbered_labels_only():
    for label in ["Анна", "Собеседник 2", "speaker_3", "Спикер 10"]:
        assert names.is_voice(label, "Борис"), label
    for label in ["Собеседник", "Speaker", "Speaker ?", "Speaker N", "Я", "me", "БОРИС", "Борис + собеседники", ""]:
        assert not names.is_voice(label, "Борис"), label


def test_generic_labels_match_the_app_rule():
    for label in ["Собеседник", "Собеседник 2", "Speaker 3", "speaker_1", "Спикер ?", "Speaker N", "Я", "Me",
                  "Борис + собеседники", "Me + others", "", "  ", "борис"]:
        assert names.is_generic(label, "Борис"), label
    for label in ["Анна", "Собеседница Анна", "Speaker Ann", "Борис Петров", "Вова"]:
        assert not names.is_generic(label, "Борис"), label


def test_participants_order_typed_and_same_first_names():
    p = [(0, 1, "a", "Я"), (1, 2, "b", "Александр Бородин"), (2, 3, "c", "Собеседник 2"),
         (3, 4, "d", "Александр Иванов"), (4, 5, "e", "Александр Бородин")]
    # Two people named Alexander: both stay; a typed "Александр" matches two of them, so it is not folded.
    assert names.participants(p, "Я", ["Александр", "Ира", "я"]) == [
        "Александр Бородин", "Александр Иванов", "Александр", "Ира"]
    # One fuller speaking name: the typed first name is that person.
    assert names.participants(p[:3], "Я", ["александр", "Ира"]) == ["Александр Бородин", "Ира"]
    # Case-insensitive duplicates and the user's own name are dropped, extra spaces are squeezed.
    assert names.participants([(0, 1, "x", "Ира  Ли")], "Борис", ["ира ли", "Борис", "Speaker ?"]) == ["Ира Ли"]
    assert names.participants([], "Я", []) == []


def test_summary_prompt_lists_participants():
    ru = summary.build_prompt("[00:00] Я: привет", "Борис", lang="ru", people=["Анна", "Влад"])
    assert "Я в звонке: Борис.\nДругие участники: Анна, Влад.\n" in ru
    en = summary.build_prompt("[00:00] Me: hi", "Boris", lang="en", people=["Ann"])
    assert "I am on the call as: Boris.\nOther participants: Ann.\n" in en
    assert "Другие участники" not in summary.build_prompt("x", "Я", lang="ru")


def test_resolve_names_rejects_generic_and_taken_names_ignoring_case(monkeypatch, tmp_path):
    monkeypatch.setattr(llm, "run", lambda p, c, **kw: ('{"Собеседник 1": "Собеседник 3", "Собеседник 2": "влад"}',
                                                         "claude", ""))
    out = names.resolve_names(paras(), ["Влад"], [], "Я", tmp_path, taken={"Влад"})
    assert [w for *_, w in out][1::2] == ["Собеседник 1", "Собеседник 2"]
