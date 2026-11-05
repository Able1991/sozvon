"""Настройки движка: переменные окружения поверх .env в папке данных (docs/CONTRACT.md, раздел 2).

Переменная окружения важнее значения из .env.
"""
import os
from dataclasses import dataclass
from pathlib import Path

from . import paths

# поле -> имена ключей
KEYS = {
    "me": ("SOZVON_ME",),
    "llm": ("SOZVON_LLM",),
    "summary_model": ("SOZVON_SUMMARY_MODEL",),
    "languages": ("SOZVON_LANGUAGE",),
    "lang_switch": ("SOZVON_LANG_SWITCH",),
    "model": ("SOZVON_MODEL",),
    "smart_names": ("SOZVON_SMART_NAMES",),
    "hf_token": ("HF_TOKEN",),
    "codex_model": ("SOZVON_CODEX_MODEL",),
}
# Только из окружения процесса (их задаёт приложение при запуске, в .env их нет).
ENV_ONLY = {"threads": "SOZVON_THREADS"}

TRUE = {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    me: str = ""
    llm: str = "auto"
    summary_model: str = "sonnet"
    languages: str = "ru"
    lang_switch: bool = False
    model: str = "turbo"
    smart_names: bool = True
    hf_token: str = ""
    codex_model: str = ""
    threads: int | None = None


def read_env_file(path: Path) -> dict:
    """Ключи .env. python-dotenv, если есть; иначе простой разбор KEY=VALUE."""
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
        languages=raw["languages"] or defaults.languages,
        lang_switch=(raw["lang_switch"] or "").lower() in TRUE,
        model=raw["model"] or defaults.model,
        smart_names=(raw["smart_names"] or "1").lower() not in {"0", "false", "no", "off"},
        hf_token=raw["hf_token"] or "",
        codex_model=raw["codex_model"] or "",
        threads=int(threads) if threads.isdigit() and int(threads) > 0 else None,
    )
