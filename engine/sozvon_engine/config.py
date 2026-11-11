"""Engine settings: environment variables on top of .env in the data dir (docs/CONTRACT.md, section 2).

An environment variable overrides the value from .env.
"""
import os
from dataclasses import dataclass
from pathlib import Path

from . import paths

# field -> key names
KEYS = {
    "me": ("SOZVON_ME",),
    "llm": ("SOZVON_LLM",),
    "summary_model": ("SOZVON_SUMMARY_MODEL",),
    "summary_language": ("SOZVON_SUMMARY_LANGUAGE",),
    "languages": ("SOZVON_LANGUAGE",),
    "lang_switch": ("SOZVON_LANG_SWITCH",),
    "model": ("SOZVON_MODEL",),
    "smart_names": ("SOZVON_SMART_NAMES",),
    "hf_token": ("HF_TOKEN",),
    "codex_model": ("SOZVON_CODEX_MODEL",),
    "cursor_model": ("SOZVON_CURSOR_MODEL",),
    "server_url": ("SOZVON_SERVER_URL",),
    "server_password": ("SOZVON_SERVER_PASSWORD",),
    "sync_voices": ("SOZVON_SYNC_VOICES",),
    "sync_audio": ("SOZVON_SYNC_AUDIO",),
    "discover_ask": ("SOZVON_DISCOVER_ASK",),
}
# Process environment only (set by the app at launch, never in .env).
ENV_ONLY = {"threads": "SOZVON_THREADS"}

TRUE = {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    me: str = ""
    llm: str = "auto"
    summary_model: str = "sonnet"
    # The summary's language: "" (or "auto") is the conversation's.
    summary_language: str = ""
    languages: str = "ru"
    lang_switch: bool = False
    model: str = "turbo"
    smart_names: bool = True
    hf_token: str = ""
    codex_model: str = ""
    cursor_model: str = ""
    server_url: str = ""
    server_password: str = ""
    # Voice prints are biometric data: they go to the own server only when asked for.
    sync_voices: bool = False
    sync_audio: bool = True
    # Project discovery with Claude may also message the open Claude Code sessions. Off unless asked for.
    discover_ask: bool = False
    threads: int | None = None


def read_env_file(path: Path) -> dict:
    """Keys from .env. Uses python-dotenv if available, otherwise a simple KEY=VALUE parser."""
    path = Path(path)
    if not path.is_file():
        return {}
    try:
        from dotenv import dotenv_values
        return {k: v for k, v in dotenv_values(path).items() if v is not None}
    except ImportError:
        out = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
        return out


def load(env_file: Path | None = None, environ=None) -> Settings:
    environ = os.environ if environ is None else environ
    file_vals = read_env_file(env_file if env_file is not None else paths.engine_dir().env_file)

    def get(names):
        for source in (environ, file_vals):
            for n in names:
                v = source.get(n)
                if v is not None and str(v).strip() != "":
                    return str(v).strip()
        return None

    defaults = Settings()
    raw = {field: get(names) for field, names in KEYS.items()}
    threads = environ.get(ENV_ONLY["threads"], "").strip()
    return Settings(
        me=raw["me"] or defaults.me,
        llm=(raw["llm"] or defaults.llm).lower(),
        summary_model=raw["summary_model"] or defaults.summary_model,
        summary_language="" if (raw["summary_language"] or "").strip().lower() in ("", "auto") else raw["summary_language"].strip().lower(),
        languages=raw["languages"] or defaults.languages,
        lang_switch=(raw["lang_switch"] or "").lower() in TRUE,
        model=raw["model"] or defaults.model,
        smart_names=(raw["smart_names"] or "1").lower() not in {"0", "false", "no", "off"},
        hf_token=raw["hf_token"] or "",
        codex_model=raw["codex_model"] or "",
        cursor_model=raw["cursor_model"] or "",
        server_url=raw["server_url"] or "",
        server_password=raw["server_password"] or "",
        sync_voices=(raw["sync_voices"] or "").lower() in TRUE,
        sync_audio=(raw["sync_audio"] or "1").lower() not in {"0", "false", "no", "off"},
        discover_ask=(raw["discover_ask"] or "").lower() in TRUE,
        threads=int(threads) if threads.isdigit() and int(threads) > 0 else None,
    )
