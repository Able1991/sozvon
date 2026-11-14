"""A second model for Russian (SOZVON_MODEL_RU): Whisper detects each track's language, Russian tracks go to it."""
import json

from sozvon_engine import config, install, langid, models
from sozvon_engine.pipeline import run, transcribe


def test_ru_model_only_after_whisper_and_only_an_onnx_one():
    assert models.ru_model("turbo", "gigaam") == "gigaam"
    assert models.ru_model("turbo", "") is None
    assert models.ru_model("gigaam", "gigaam") is None, "the same model: nothing to route"
    assert models.ru_model("parakeet", "gigaam") is None, "an onnx main model can't tell the languages apart"
    assert models.ru_model("turbo", "large-v3") is None, "a second Whisper gives nothing the main one doesn't"
    assert models.ru_model("turbo", "nope") is None


def test_config_reads_the_ru_model():
    assert config.load(env_file=None, environ={"SOZVON_MODEL_RU": "gigaam"}).model_ru == "gigaam"
    assert config.load(env_file=None, environ={}).model_ru == ""


def routed(monkeypatch, lang):
    calls = []
    monkeypatch.setattr(langid, "load_audio", lambda wav: None)
    monkeypatch.setattr(langid, "detect_track", lambda audio, allowed, probs: (lang, 0.9))
    monkeypatch.setattr(transcribe, "whisper_track", lambda wav, *a, **k: calls.append(("whisper", wav)) or [])
    monkeypatch.setattr(transcribe, "onnx_track", lambda wav, d, m, r: calls.append((m, wav)) or [])
    return calls


def run_tracks(allowed, ru_model="gigaam"):
    return transcribe.transcribe_tracks(
        {"mic": "mic.wav"}, data_dir=None, model="turbo", model_path="m", allowed=allowed, switch=False,
        prompts=transcribe.Prompts(lambda lang: ("", ""), []), log=lambda *a: None, ru_model=ru_model)


def test_a_russian_track_goes_to_the_ru_model(monkeypatch):
    calls = routed(monkeypatch, "ru")
    _, langs = run_tracks(["ru", "en"])
    assert calls == [("gigaam", "mic.wav")] and langs == {"mic": "ru"}


def test_an_english_track_stays_on_whisper(monkeypatch):
    calls = routed(monkeypatch, "en")
    run_tracks(None)
    assert calls == [("whisper", "mic.wav")]


def test_russian_only_call_skips_detection(monkeypatch):
    calls = routed(monkeypatch, "en")   # would say English if asked
    run_tracks(["ru"])
    assert calls == [("gigaam", "mic.wav")]


def test_without_a_ru_model_everything_is_whisper(monkeypatch):
    calls = routed(monkeypatch, "ru")
    run_tracks(["ru"], ru_model=None)
    assert calls == [("whisper", "mic.wav")]


def spec(tmp_path, call, environ, profile=None):
    if profile is not None:
        (tmp_path / "profiles").mkdir(exist_ok=True)
    s = config.load(env_file=None, environ=environ)
    return run.build_spec(tmp_path, {"id": "x", **call}, run.parse_args([str(tmp_path)]), s)


def test_a_model_chosen_for_the_call_wins(tmp_path):
    sp = spec(tmp_path, {"model": "large-v3"}, {"SOZVON_MODEL": "turbo", "SOZVON_MODEL_RU": "gigaam"})
    assert (sp.model, sp.ru_model) == ("large-v3", None)


def test_auto_uses_the_settings(tmp_path):
    sp = spec(tmp_path, {}, {"SOZVON_MODEL": "turbo", "SOZVON_MODEL_RU": "gigaam"})
    assert (sp.model, sp.ru_model) == ("turbo", "gigaam")
    sp = spec(tmp_path, {"model": "bogus"}, {"SOZVON_MODEL": "turbo"})
    assert (sp.model, sp.ru_model) == ("turbo", None), "an unknown model in call.json is auto"


def test_project_language_when_the_call_has_none(tmp_path, monkeypatch):
    from sozvon_engine import profiles
    monkeypatch.setattr(profiles, "load", lambda slug: {"languages": "en"} if slug == "acme" else {})
    assert spec(tmp_path, {"profile": "acme"}, {"SOZVON_LANGUAGE": "ru"}).languages == "en"
    assert spec(tmp_path, {"profile": "acme", "languages": "ru"}, {}).languages == "ru", "the call's own choice wins"


def test_install_downloads_both_models(tmp_path, monkeypatch):
    got = []
    monkeypatch.setattr(install, "ensure_model", lambda root, name, dl: got.append(name))
    monkeypatch.setattr(install, "ensure_echo_model", lambda *a: None)
    monkeypatch.setattr(install, "install_pyannote", lambda *a: True)
    (tmp_path / ".env").write_text("SOZVON_MODEL=turbo\nSOZVON_MODEL_RU=gigaam\n")
    (tmp_path / "hf-cache").mkdir()
    install.main([str(tmp_path)])
    assert got == ["turbo", "gigaam"]
