"""Where engine data and calls live: the single source of truth for all modules.

Data dir (code, .venv, models, projects, vocabulary):
  1. SOZVON_DATA_DIR (set by the app);
  2. the folder above the package if it contains server.py (run from the repo or an installed engine);
  3. ~/Library/Application Support/Sozvon.
Calls dir: SOZVON_CALLS_DIR, otherwise ~/Documents/Calls.
Values are read on every call: tests and processes with a different environment see their own folders.
"""
import os
from dataclasses import dataclass
from pathlib import Path

CODE_DIR = Path(__file__).resolve().parent.parent  # where server.py, models.json, ENGINE_VERSION live
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
    def wespeaker_cache(self) -> Path:
        return self.hf_cache / "models--pyannote--wespeaker-voxceleb-resnet34-LM"

    @property
    def voices(self) -> Path:
        return self.root / "voices"

    @property
    def voices_deleted(self) -> Path:
        return self.root / "voices-deleted.json"

    @property
    def no_diarization(self) -> Path:
        return self.root / ".no-diarization"

    @property
    def index(self) -> Path:
        return self.root / "index.db"

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
    """Code version: ENGINE_VERSION next to server.py, otherwise the .engine-version marker in the data dir."""
    for f in (CODE_DIR / "ENGINE_VERSION", data_dir() / ".engine-version"):
        try:
            v = f.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if v:
            return v
    return "dev"
