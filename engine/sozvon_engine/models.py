"""ASR models from the models.json manifest: which exist, where they live, whether downloaded.

A downloaded model is marked with a .complete file: the app and the engine use it to tell a full
download from an interrupted one. The revision is pinned in the manifest. Downloading lives in install.py.
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
    """{short name: manifest entry} for Whisper models only."""
    return {k: v for k, v in MODELS.items() if v["kind"] == "whisper"}


def model_dir(data_dir, name: str) -> Path:
    return Path(data_dir) / "models" / MODELS[name]["dir"]


def vad_dir(data_dir) -> Path:
    return Path(data_dir) / "models" / VAD["dir"]


def files_present(d: Path, files) -> bool:
    return all((d / f).exists() and (d / f).stat().st_size > 0 for f in files)


def is_complete(d: Path, files) -> bool:
    # Installs before 0.1 did not write the marker: treat as complete if all files exist and are non-empty.
    return (d / COMPLETE).exists() or files_present(d, files)


def is_downloaded(data_dir, name: str) -> bool:
    m = MODELS[name]
    ok = is_complete(model_dir(data_dir, name), m["files"])
    if m["kind"] == "onnx":
        ok = ok and is_complete(vad_dir(data_dir), VAD["files"])
    return ok


def local_whisper(data_dir, name: str) -> str | None:
    """Path to a downloaded Whisper model for mlx-whisper; None if the name is unknown or not downloaded."""
    if kind(name) != "whisper" or not is_downloaded(data_dir, name):
        return None
    return str(model_dir(data_dir, name))


def ru_model(main: str, ru: str) -> str | None:
    """The model for Russian tracks when it is not the main one. Only after a Whisper main model, whose language
    detection sorts the tracks (an onnx model can't tell languages), and only an onnx one (GigaAM): a second Whisper
    gives nothing the main one doesn't."""
    if not ru or ru == main or ru not in MODELS or main not in MODELS or is_onnx(main) or not is_onnx(ru):
        return None
    return ru
