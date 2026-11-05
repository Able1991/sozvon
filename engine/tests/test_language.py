"""Call language: the base prompt must not pull Whisper into Russian; texts follow the app language."""
from sozvon_engine import i18n, llm, prompt
from sozvon_engine.pipeline import summary

RU = {"initial_prompt": "Деловой созвон на русском языке.", "terms": ["x"]}


def test_russian_keeps_prompt():
    assert prompt.vocab_for_language(RU, "ru") is RU


def test_english_gets_english_base():
    v = prompt.vocab_for_language(RU, "en")
    assert v["initial_prompt"] == "A business call in English." and v["terms"] == ["x"]


def test_auto_and_unknown_get_empty_base():
    assert prompt.vocab_for_language(RU, None)["initial_prompt"] == ""
    assert prompt.vocab_for_language(RU, "fr")["initial_prompt"] == ""


def test_custom_prompt_is_respected():
    custom = {"initial_prompt": "Созвон команды Acme."}
    assert prompt.vocab_for_language(custom, "en") is custom


def test_ui_texts_follow_app_language(monkeypatch):
    monkeypatch.setenv("SOZVON_UI_LANG", "en")
    assert i18n.t("speaker_n", n=2) == "Speaker 2" and i18n.t("transcript") == "Transcript"
    monkeypatch.setenv("SOZVON_UI_LANG", "ru")
    assert i18n.t("speaker_n", n=2) == "Собеседник 2"
    monkeypatch.setenv("SOZVON_UI_LANG", "de")  # no translation: English
    assert i18n.t("call") == "Call"
    monkeypatch.setenv("SOZVON_UI_LANG", "ru_RU")
    assert i18n.t("call") == "Звонок"


def test_every_message_has_both_languages():
    import string
    for key, (ru, en) in i18n.MESSAGES.items():
        fields = lambda s: {f for _, f, _, _ in string.Formatter().parse(s) if f}  # noqa: E731
        assert fields(ru) == fields(en), key


def test_summary_prompt_language(monkeypatch, tmp_path):
    seen = {}
    monkeypatch.setattr(llm, "run", lambda prompt, cwd, **kw: (seen.setdefault("p", prompt), "claude", ""))
    monkeypatch.setenv("SOZVON_UI_LANG", "en")
    summary.summarize("[00:00] Me: hi", "Me", tmp_path, "ctx")
    assert "Write a short summary in English" in seen["p"] and "Context" in seen["p"]
    seen.clear()
    monkeypatch.setenv("SOZVON_UI_LANG", "ru")
    summary.summarize("[00:00] Я: привет", "Я", tmp_path)
    assert "саммари на русском" in seen["p"]


def test_summary_strips_long_dashes(monkeypatch, tmp_path):
    em = "\u2014"
    monkeypatch.setattr(llm, "run", lambda prompt, cwd, **kw: (f"Итог {em} запуск", "claude", ""))
    assert summary.summarize("x", "Я", tmp_path) == "Итог, запуск"
