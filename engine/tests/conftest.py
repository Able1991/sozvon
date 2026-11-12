"""Shared fixtures. The sozvon_engine package is loaded from the repository (engine/).

Each test gets its own empty data folder (SOZVON_DATA_DIR) and calls folder.
Slow tests (real Whisper) are marked @pytest.mark.slow and need an installed
engine with models: SOZVON_TEST_ENGINE=<folder with models/> or ~/Library/Application Support/Sozvon.
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
           "SOZVON_LANG_SWITCH", "SOZVON_SMART_NAMES", "SOZVON_SUMMARY_MODEL", "SOZVON_SUMMARY_LANGUAGE", "SOZVON_CODEX_MODEL",
           "SOZVON_CURSOR_MODEL",
           "HF_TOKEN", "SOZVON_THREADS", "SOZVON_MCP_TOKEN", "SOZVON_SERVER_URL", "SOZVON_SERVER_PASSWORD",
           "SOZVON_SYNC_VOICES", "SOZVON_SYNC_AUDIO"):
    os.environ.pop(_k, None)


def pytest_configure(config):
    config.addinivalue_line("markers", "slow: the real Whisper on synthesized speech")


@pytest.fixture(autouse=True)
def data(tmp_path, monkeypatch):
    """Empty engine data folder and calls folder instead of the real ones."""
    d = tmp_path / "data"
    d.mkdir()
    monkeypatch.setenv("SOZVON_DATA_DIR", str(d))
    monkeypatch.setenv("SOZVON_CALLS_DIR", str(tmp_path / "Calls"))
    monkeypatch.setenv("SOZVON_UI_LANG", "ru")
    return d


@pytest.fixture(autouse=True)
def no_real_trash(monkeypatch):
    """Sync moves calls deleted on another Mac to the Trash: tests pass their own trash function, and the
    real one (osascript, ~/.Trash) fails the test if anything reaches it."""
    from sozvon_engine import remote

    def refuse(path):
        raise AssertionError(f"tests never use the real Trash: {path}")

    monkeypatch.setattr(remote, "move_to_trash", refuse)


@pytest.fixture
def profiles(data):
    d = data / "profiles"
    d.mkdir()
    return d


def fake_model(data: Path, name: str = "turbo") -> Path:
    """A "downloaded" model without weights: placeholder files and a .complete marker."""
    from sozvon_engine import models
    d = models.model_dir(data, name)
    d.mkdir(parents=True, exist_ok=True)
    for f in models.MODELS[name]["files"]:
        (d / f).write_text("x")
    (d / models.COMPLETE).write_text("test\n")
    return d


def slow_model() -> str:
    """The Whisper model the slow tests expect (SOZVON_TEST_MODEL, default turbo; the quality workflow uses small)."""
    return os.environ.get("SOZVON_TEST_MODEL") or "turbo"


def installed_engine():
    """A data folder with a .venv and the test model downloaded, or None."""
    from sozvon_engine import models, platform_support
    name = slow_model()
    if name not in models.MODELS:
        return None
    python = ".venv/Scripts/python.exe" if os.name == "nt" else ".venv/bin/python3"
    for c in (os.environ.get("SOZVON_TEST_ENGINE"), str(platform_support.default_data_dir())):
        if c and models.is_downloaded(c, name) and (Path(c) / python).exists():
            return Path(c)
    return None
