"""Где лежат данные движка и звонки: одна точка правды для всех модулей.

Папка данных (код, .venv, модели, проекты, словарь):
  1. SOZVON_DATA_DIR (задаёт приложение);
  2. папка над пакетом, если там server.py (запуск из репозитория или из установленного движка);
  3. ~/Library/Application Support/Sozvon.
Папка звонков: SOZVON_CALLS_DIR, иначе ~/Documents/Calls.
Значения читаются при каждом вызове: тесты и процессы с другим окружением видят свои папки.
"""
import os
from dataclasses import dataclass
from pathlib import Path

CODE_DIR = Path(__file__).resolve().parent.parent  # где server.py, models.json, ENGINE_VERSION
DEFAULT_DATA_DIR = Path.home() / "Library" / "Application Support" / "Sozvon"
DEFAULT_CALLS_DIR = Path.home() / "Documents" / "Calls"


@dataclass(frozen=True)
class EngineDir:
    root: Path

    @property
    def models(self) -> Path:
        return self.root / "models"

    @property
    def profiles(self) -> Path:
        return self.root / "profiles"

    @property
    def vocab(self) -> Path:
        return self.root / "vocab.json"

    @property
    def env_file(self) -> Path:
        return self.root / ".env"

    @property
    def hf_cache(self) -> Path:
        return self.root / "hf-cache"

    @property
    def pyannote_cache(self) -> Path:
        return self.hf_cache / "models--pyannote--speaker-diarization-3.1"

    @property
    def no_diarization(self) -> Path:
        return self.root / ".no-diarization"

    @property
    def venv_lock(self) -> Path:
        return self.root / ".venv-lock"

    @property
    def installed(self) -> Path:
        return self.root / ".installed"


def data_dir() -> Path:
    value = os.environ.get("SOZVON_DATA_DIR")
    if value:
        return Path(value).expanduser()
    if (CODE_DIR / "server.py").exists():
        return CODE_DIR
    return DEFAULT_DATA_DIR


def engine_dir() -> EngineDir:
    return EngineDir(data_dir())


def calls_dir() -> Path:
    value = os.environ.get("SOZVON_CALLS_DIR")
    return Path(value).expanduser() if value else DEFAULT_CALLS_DIR


def engine_version() -> str:
    """Версия кода: ENGINE_VERSION рядом с server.py, иначе метка .engine-version в папке данных."""
    for f in (CODE_DIR / "ENGINE_VERSION", data_dir() / ".engine-version"):
        try:
            v = f.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if v:
            return v
    return "dev"
