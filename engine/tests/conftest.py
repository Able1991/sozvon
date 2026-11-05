"""Общие фикстуры. Пакет sozvon_engine грузится из репозитория (engine/).

Каждый тест получает свою пустую папку данных (SOZVON_DATA_DIR) и папку звонков.
Медленные тесты (настоящий Whisper) помечены @pytest.mark.slow и требуют установленный
движок с моделями: SOZVON_TEST_ENGINE=<папка с models/> или ~/Library/Application Support/Sozvon.
"""
import os
import sys
from pathlib import Path

import pytest

ENGINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ENGINE))
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["SOZVON_UI_LANG"] = "ru"
for _k in ("SOZVON_ME", "SOZVON_LLM", "SOZVON_MODEL", "SOZVON_LANGUAGE",
           "SOZVON_LANG_SWITCH", "SOZVON_SMART_NAMES", "SOZVON_SUMMARY_MODEL", "SOZVON_CODEX_MODEL",
           "HF_TOKEN", "SOZVON_THREADS", "SOZVON_MCP_TOKEN"):
    os.environ.pop(_k, None)


def pytest_configure(config):
    config.addinivalue_line("markers", "slow: настоящий Whisper на синтезированной речи")


@pytest.fixture(autouse=True)
def data(tmp_path, monkeypatch):
    """Пустая папка данных движка и папка звонков вместо настоящих."""
    d = tmp_path / "data"
    d.mkdir()
    monkeypatch.setenv("SOZVON_DATA_DIR", str(d))
    monkeypatch.setenv("SOZVON_CALLS_DIR", str(tmp_path / "Calls"))
    monkeypatch.setenv("SOZVON_UI_LANG", "ru")
    return d


@pytest.fixture
def profiles(data):
    d = data / "profiles"
    d.mkdir()
    return d


def fake_model(data: Path, name: str = "turbo") -> Path:
    """Скачанная модель без весов: файлы-пустышки и метка .complete."""
    from sozvon_engine import models
    d = models.model_dir(data, name)
    d.mkdir(parents=True, exist_ok=True)
    for f in models.MODELS[name]["files"]:
        (d / f).write_text("x")
    (d / models.COMPLETE).write_text("test\n")
    return d


def installed_engine():
    for c in (os.environ.get("SOZVON_TEST_ENGINE"), str(Path.home() / "Library/Application Support/Sozvon")):
        if c and (Path(c) / "models/whisper-large-v3-turbo/weights.safetensors").exists():
            return Path(c)
    return None
