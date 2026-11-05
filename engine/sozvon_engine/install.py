"""Установка моделей и меток движка (вызывается из setup.sh после uv sync).

Что делает, всё повторно безопасно:
  1. модель распознавания из models.json закреплённой ревизии (SOZVON_MODEL, по умолчанию turbo),
     для onnx-моделей ещё детектор пауз; скачанное помечается .complete, старые полные
     загрузки без метки помечаются без повторного скачивания;
  2. модели pyannote для разбивки по голосам: архив из бандла приложения (SOZVON_PYANNOTE_TAR),
     если он битый или его нет, из сети; SHA-256 проверяется; не вышло: метка .no-diarization;
  3. .venv-lock (первые 16 символов SHA-256 от uv.lock) и .installed (время установки).
Строки «==> …» показывает окно установки приложения.
"""
import hashlib
import os
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Callable

from . import config, models
from .i18n import t
from .paths import EngineDir

PYANNOTE_URL = "https://github.com/Able1991/sozvon/releases/download/models-v1/pyannote-models-v1.tar.gz"
PYANNOTE_SHA = "0b9d5795aea1f8a2a943d4b4d8beaab0128f1cec5561de4d2f4573e3726d90d6"

# downloader(repo, filename, revision, local_dir): скачать один файл репозитория Hugging Face.
Downloader = Callable[[str, str, str, Path], None]
# fetcher(url, dest): скачать URL (https:// или file://) в файл; исключение при сбое.
Fetcher = Callable[[str, Path], None]


def step(msg: str) -> None:
    print(f"==> {msg}", flush=True)


def hf_download(repo: str, filename: str, revision: str, local_dir: Path) -> None:
    from huggingface_hub import hf_hub_download
    hf_hub_download(repo, filename, revision=revision, local_dir=local_dir)


def curl_fetch(url: str, dest: Path) -> None:
    subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(dest), url], check=True)


def ensure_entry(entry: dict, d: Path, downloader: Downloader) -> None:
    """Одна запись манифеста (модель или детектор пауз) в папку d."""
    if (d / models.COMPLETE).exists():
        return
    if models.files_present(d, entry["files"]):
        # Скачано до появления меток (установки до 0.1): не качаем заново, только помечаем.
        (d / models.COMPLETE).write_text("legacy\n")
        return
    d.mkdir(parents=True, exist_ok=True)
    for f in entry["files"]:
        downloader(entry["repo"], f, entry["revision"], d)
    (d / models.COMPLETE).write_text(entry["revision"] + "\n")


def ensure_model(data: Path, name: str, downloader: Downloader = hf_download) -> Path:
    """Скачать модель закреплённой ревизии (и детектор пауз для onnx-моделей)."""
    if name not in models.MODELS:
        raise ValueError(f"unknown model {name!r}; available: {', '.join(models.MODELS)}")
    m = models.MODELS[name]
    d = models.model_dir(data, name)
    ensure_entry(m, d, downloader)
    if m["kind"] == "onnx":
        ensure_entry(models.VAD, models.vad_dir(data), downloader)
    return d


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def pyannote_sources(bundled: str | None, url: str) -> list:
    """Архив из бандла важнее сети; сеть остаётся запасным вариантом."""
    out = []
    if bundled and Path(bundled).is_file():
        out.append(Path(bundled).resolve().as_uri())
    out.append(url)
    return out


def install_pyannote(engine: EngineDir, sources: list, sha: str = PYANNOTE_SHA,
                     fetch: Fetcher = curl_fetch) -> bool:
    """Модели разбивки по голосам в <data>/hf-cache. -> установлены ли."""
    if engine.pyannote_cache.is_dir():
        return True
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "pyannote.tar.gz"
        for url in sources:
            try:
                archive.unlink(missing_ok=True)
                fetch(url, archive)
                if sha256(archive) != sha:
                    continue
                # filter="data" (PEP 706) отбрасывает абсолютные пути, ../ и ссылки наружу;
                # правило trailofbits этот фильтр не распознаёт
                with tarfile.open(archive, "r:gz") as tar:  # nosemgrep: trailofbits.python.tarfile-extractall-traversal.tarfile-extractall-traversal
                    tar.extractall(engine.root, filter="data")
            except (OSError, subprocess.CalledProcessError, tarfile.TarError):
                continue
            if engine.pyannote_cache.is_dir():
                engine.no_diarization.unlink(missing_ok=True)
                return True
    engine.no_diarization.touch()
    return False


def write_markers(engine: EngineDir) -> None:
    """Под какой uv.lock собрано окружение и когда: по ним приложение решает, нужна ли переустановка."""
    lock = engine.root / "uv.lock"
    if lock.exists():
        engine.venv_lock.write_text(sha256(lock)[:16] + "\n")
    engine.installed.write_text(f"{int(time.time())}\n")


def main(argv=None, downloader: Downloader = hf_download, fetch: Fetcher = curl_fetch) -> int:
    argv = sys.argv[1:] if argv is None else argv
    engine = EngineDir(Path(argv[0] if argv else ".").expanduser().resolve())
    settings = config.load(env_file=engine.env_file)
    # Без шума в окне установки: предупреждения библиотек и прогресс-бары с \r.
    os.environ.update(HF_HUB_OFFLINE="0", HF_HUB_VERBOSITY="error", HF_HUB_DISABLE_PROGRESS_BARS="1")
    if settings.hf_token:
        # Свой токен (не обязателен): выше лимиты Hugging Face, если качают многие с одного IP.
        os.environ["HF_TOKEN"] = settings.hf_token

    model = settings.model if settings.model in models.MODELS else models.DEFAULT_MODEL
    step(t("install_model", model=model))
    ensure_model(engine.root, model, downloader)

    if not engine.pyannote_cache.is_dir():
        step(t("install_pyannote"))
        sources = pyannote_sources(os.environ.get("SOZVON_PYANNOTE_TAR"),
                                   os.environ.get("SOZVON_PYANNOTE_URL") or PYANNOTE_URL)
        if not install_pyannote(engine, sources, os.environ.get("SOZVON_PYANNOTE_SHA") or PYANNOTE_SHA, fetch):
            print(t("install_no_diarization"), flush=True)

    write_markers(engine)
    step(t("install_done"))
    return 0
