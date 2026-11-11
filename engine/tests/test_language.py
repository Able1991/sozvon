"""Call language: the base prompt must not pull Whisper into Russian; texts follow the app language."""
import pytest

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


def test_summary_prompt_key_moments_only_with_marks():
    from sozvon_engine.pipeline import summary as s
    assert "Важные моменты" not in s.build_prompt("x", "Я", lang="ru")
    p = s.build_prompt("x", "Я", lang="ru", marks=["12:30", "25:10"])
    assert "## Важные моменты" in p and "12:30, 25:10" in p
    assert p.index("## Важные моменты") < p.index("## Решения")
    assert "## Key Moments" in s.build_prompt("x", "Me", lang="en", marks=["01:00"])


def test_errors_raised_by_the_engine_follow_the_app_language(monkeypatch, tmp_path):
    """They end up in process.log and in call.json warnings, so an English interface gets English."""
    from sozvon_engine import diarize, jsonfile
    f = tmp_path / "list.json"
    f.write_text("[1, 2]")
    monkeypatch.setattr(diarize, "_pipeline", None)
    monkeypatch.setattr(diarize, "available", lambda: False)
    for ui, not_object, no_models in [("ru", "ожидался JSON-объект", "нет моделей pyannote: переустанови движок"),
                                      ("en", "a JSON object was expected", "no pyannote models: reinstall the engine")]:
        monkeypatch.setenv("SOZVON_UI_LANG", ui)
        with pytest.raises(jsonfile.JsonFileError) as e:
            jsonfile.read(f, strict=True)
        assert str(e.value) == f"{f}: {not_object}"
        with pytest.raises(diarize.DiarizationUnavailable) as e:
            diarize.load_pipeline()
        assert str(e.value) == no_models
