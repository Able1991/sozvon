"""Install engine models and markers (called from setup.sh after uv sync).

Steps, all safe to rerun:
  1. the ASR model from models.json at its pinned revision (SOZVON_MODEL, default turbo),
     plus the voice activity detector for onnx models; downloads are marked .complete, old
     complete downloads without a marker are marked without re-downloading;
  2. pyannote diarization models: the archive from the app bundle (SOZVON_PYANNOTE_TAR),
     or from the network if it is missing or broken; SHA-256 is verified; on failure: .no-diarization marker;
  3. .venv-lock (first 16 characters of the uv.lock SHA-256) and .installed (install time).
The app's install window shows the "==> ..." lines.
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

# downloader(repo, filename, revision, local_dir): download one file from a Hugging Face repo.
Downloader = Callable[[str, str, str, Path], None]
# fetcher(url, dest): download a URL (https:// or file://) to a file; raises on failure.
Fetcher = Callable[[str, Path], None]


def step(msg: str) -> None:
    print(f"==> {msg}", flush=True)


def hf_download(repo: str, filename: str, revision: str, local_dir: Path) -> None:
    from huggingface_hub import hf_hub_download
    hf_hub_download(repo, filename, revision=revision, local_dir=local_dir)


def curl_fetch(url: str, dest: Path) -> None:
    subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(dest), url], check=True)


def ensure_entry(entry: dict, d: Path, downloader: Downloader) -> None:
    """One manifest entry (model or voice activity detector) into folder d."""
    if (d / models.COMPLETE).exists():
        return
    if models.files_present(d, entry["files"]):
        # Downloaded before markers existed (installs before 0.1): mark it, do not re-download.
        (d / models.COMPLETE).write_text("legacy\n")
        return
    d.mkdir(parents=True, exist_ok=True)
    for f in entry["files"]:
        downloader(entry["repo"], f, entry["revision"], d)
    (d / models.COMPLETE).write_text(entry["revision"] + "\n")


def ensure_model(data: Path, name: str, downloader: Downloader = hf_download) -> Path:
    """Download a model at its pinned revision (plus the VAD for onnx models)."""
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
    """The bundled archive takes priority; the network is the fallback."""
    out = []
    if bundled and Path(bundled).is_file():
        out.append(Path(bundled).resolve().as_uri())
    out.append(url)
    return out


def install_pyannote(engine: EngineDir, sources: list, sha: str = PYANNOTE_SHA,
                     fetch: Fetcher = curl_fetch) -> bool:
    """Diarization models into <data>/hf-cache. -> whether installed."""
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
                # filter="data" (PEP 706) rejects absolute paths, ../ and links pointing outside;
                # the trailofbits rule does not recognize this filter
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
    """Which uv.lock the environment was built from and when: the app uses this to decide on reinstall."""
    lock = engine.root / "uv.lock"
    if lock.exists():
        engine.venv_lock.write_text(sha256(lock)[:16] + "\n")
    engine.installed.write_text(f"{int(time.time())}\n")


def main(argv=None, downloader: Downloader = hf_download, fetch: Fetcher = curl_fetch) -> int:
    argv = sys.argv[1:] if argv is None else argv
    engine = EngineDir(Path(argv[0] if argv else ".").expanduser().resolve())
    settings = config.load(env_file=engine.env_file)
    # Keep the install window clean: no library warnings or \r progress bars.
    os.environ.update(HF_HUB_OFFLINE="0", HF_HUB_VERBOSITY="error", HF_HUB_DISABLE_PROGRESS_BARS="1")
    if settings.hf_token:
        # Own token (optional): higher Hugging Face limits when many download from one IP.
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
