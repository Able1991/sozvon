"""Engine settings: new keys, legacy names, environment overrides .env; folders."""
from pathlib import Path

from sozvon_engine import config, paths


def write_env(data: Path, text: str) -> Path:
    f = data / ".env"
    f.write_text(text)
    return f


def test_defaults(data):
    s = config.load(environ={})
    assert s == config.Settings()
    assert s.model == "turbo" and s.llm == "auto" and s.smart_names and not s.lang_switch


def test_new_keys_from_env_file(data):
    write_env(data, "SOZVON_ENV_VERSION=1\nSOZVON_ME=Олег\nSOZVON_LLM=Codex\nSOZVON_SUMMARY_MODEL=opus\n"
                    "SOZVON_LANGUAGE=ru,en\nSOZVON_LANG_SWITCH=1\nSOZVON_MODEL=gigaam\nSOZVON_SMART_NAMES=0\n"
                    "HF_TOKEN=hf_x\n")
    s = config.load(environ={})
    assert (s.me, s.llm, s.summary_model, s.languages) == ("Олег", "codex", "opus", "ru,en")
    assert s.lang_switch and s.model == "gigaam" and not s.smart_names and s.hf_token == "hf_x"


def test_old_names_are_ignored(data):
    write_env(data, "CALL_ME_NAME=Старое\nCALL_SUMMARY_MODEL=haiku\nCODEX_MODEL=o3\n")
    s = config.load(environ={"CALL_ME_NAME": "Старое"})
    assert (s.me, s.summary_model, s.codex_model) == ("", "sonnet", "")


def test_codex_model(data):
    write_env(data, "SOZVON_CODEX_MODEL=gpt-5\n")
    assert config.load(environ={}).codex_model == "gpt-5"


def test_cursor_llm_and_model(data):
    write_env(data, "SOZVON_LLM=Cursor\nSOZVON_CURSOR_MODEL=sonnet-4\n")
    s = config.load(environ={})
    assert (s.llm, s.cursor_model, s.codex_model) == ("cursor", "sonnet-4", "")
    assert config.load(environ={"SOZVON_CURSOR_MODEL": "gpt-5"}).cursor_model == "gpt-5"
    assert config.load(environ={}).cursor_model == "sonnet-4"


def test_env_overrides_env_file(data):
    write_env(data, "SOZVON_ME=Из файла\nSOZVON_MODEL=small\nSOZVON_LANG_SWITCH=1\n")
    s = config.load(environ={"SOZVON_ME": "Из окружения", "SOZVON_MODEL": "turbo", "SOZVON_LANG_SWITCH": "0"})
    assert s.me == "Из окружения" and s.model == "turbo" and not s.lang_switch


def test_empty_values_are_ignored(data):
    write_env(data, "SOZVON_ME=\nSOZVON_MODEL=small\n")
    s = config.load(environ={"SOZVON_MODEL": ""})
    assert s.me == "" and s.model == "small"


def test_threads_only_from_environment(data):
    write_env(data, "SOZVON_THREADS=8\n")
    assert config.load(environ={}).threads is None
    assert config.load(environ={"SOZVON_THREADS": "2"}).threads == 2
    assert config.load(environ={"SOZVON_THREADS": "x"}).threads is None


def test_data_dir_order(monkeypatch, tmp_path):
    monkeypatch.setenv("SOZVON_DATA_DIR", str(tmp_path / "new"))
    assert paths.data_dir() == tmp_path / "new"
    monkeypatch.delenv("SOZVON_DATA_DIR")
    monkeypatch.setenv("WHISPER_MCP_DIR", str(tmp_path / "old"))
    assert paths.data_dir() == paths.CODE_DIR, "from the repository: the folder with server.py"


def test_calls_dir(monkeypatch, tmp_path):
    monkeypatch.setenv("SOZVON_CALLS_DIR", str(tmp_path / "C"))
    assert paths.calls_dir() == tmp_path / "C"
    monkeypatch.delenv("SOZVON_CALLS_DIR")
    assert paths.calls_dir() == paths.DEFAULT_CALLS_DIR  # the folder itself: test_platform_support, test_platform_win32


def test_engine_version(monkeypatch, data):
    monkeypatch.setattr(paths, "CODE_DIR", data / "code")
    assert paths.engine_version() == "dev"
    (data / ".engine-version").write_text("stamp\n")
    assert paths.engine_version() == "stamp"
    (data / "code").mkdir()
    (data / "code" / "ENGINE_VERSION").write_text("aad392548a91a7b4\n")
    assert paths.engine_version() == "aad392548a91a7b4"
