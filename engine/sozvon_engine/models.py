"""Модели распознавания по манифесту models.json: какие есть, где лежат, скачаны ли.

Скачанная модель помечается файлом .complete: по нему приложение и движок отличают полную
загрузку от оборванной. Ревизия закреплена в манифесте. Скачивание живёт в install.py.
"""
import json
from pathlib import Path

from . import paths

MANIFEST_FILE = paths.CODE_DIR / "models.json"
MANIFEST = json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))
MODELS: dict = MANIFEST["models"]
VAD: dict = MANIFEST["vad"]
COMPLETE = ".complete"
DEFAULT_MODEL = "turbo"


def kind(name: str) -> str | None:
    return MODELS.get(name, {}).get("kind")


def is_onnx(name: str) -> bool:
    return kind(name) == "onnx"


def whisper_models() -> dict:
    """{короткое имя: запись манифеста} только для моделей Whisper."""
    return {k: v for k, v in MODELS.items() if v["kind"] == "whisper"}


def model_dir(data_dir, name: str) -> Path:
    return Path(data_dir) / "models" / MODELS[name]["dir"]


def vad_dir(data_dir) -> Path:
    return Path(data_dir) / "models" / VAD["dir"]


def files_present(d: Path, files) -> bool:
    return all((d / f).exists() and (d / f).stat().st_size > 0 for f in files)


def is_complete(d: Path, files) -> bool:
    # Установки до 0.1 не ставили метку: считаем полной, если все файлы на месте и не пустые.
    return (d / COMPLETE).exists() or files_present(d, files)


def is_downloaded(data_dir, name: str) -> bool:
    m = MODELS[name]
    ok = is_complete(model_dir(data_dir, name), m["files"])
    if m["kind"] == "onnx":
        ok = ok and is_complete(vad_dir(data_dir), VAD["files"])
    return ok


def local_whisper(data_dir, name: str) -> str | None:
    """Путь к скачанной модели Whisper для mlx-whisper; None, если имени нет или модель не скачана."""
    if kind(name) != "whisper" or not is_downloaded(data_dir, name):
        return None
    return str(model_dir(data_dir, name))
