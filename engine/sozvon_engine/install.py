"""Install engine models and markers (called from setup.sh after uv sync).

Steps, all safe to rerun:
  1. the ASR model from models.json at its pinned revision (SOZVON_MODEL, default turbo),
     plus the voice activity detector for onnx models; downloads are marked .complete, old
     complete downloads without a marker are marked without re-downloading;
  2. the echo suppressor's weights (models.json key "aec"): optional, the classic filter works without them;
     SHA-256 is verified, a bad copy is fetched once more, a failed download leaves a .no-echo-model marker;
  3. pyannote diarization models: the archive from the app bundle (SOZVON_PYANNOTE_TAR),
     or from the network if it is missing or broken; SHA-256 is verified; on failure: .no-diarization marker;
  4. .venv-lock (first 16 characters of the uv.lock SHA-256) and .installed (install time).
The app's install window shows the "==> ..." lines.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Callable

from . import accel, config, models, platform_support
from .i18n import t
from .paths import EngineDir

PYANNOTE_URL = "https://github.com/Able1991/sozvon/releases/download/models-v1/pyannote-models-v1.tar.gz"
PYANNOTE_SHA = "0b9d5795aea1f8a2a943d4b4d8beaab0128f1cec5561de4d2f4573e3726d90d6"
PREVIOUS_ECHO_DIRS = ("localvqe-v1.3",)   # models.json key "aec" used to point here

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
    subprocess.run([platform_support.tool_path("curl"), "-fsSL", "--retry", "3", "-o", str(dest), url], check=True)


def ensure_entry(entry: dict, d: Path, downloader: Downloader) -> None:
    """One manifest entry (model or voice activity detector) into folder d."""
    if (d / models.COMPLETE).exists():
        return
    if models.files_present(d, entry["files"]):
        # Downloaded before markers existed (installs before 0.1): mark it, do not re-download.
        verify_files(entry, d)
        (d / models.COMPLETE).write_text("legacy\n")
        return
    d.mkdir(parents=True, exist_ok=True)
    for attempt in range(2):
        for f in entry["files"]:
            downloader(entry["repo"], f, entry["revision"], d)
        try:
            verify_files(entry, d)
            break
        except ValueError:  # a broken download: one more try, then the error reaches the installer
            if attempt:
                raise
    (d / models.COMPLETE).write_text(entry["revision"] + "\n")


def verify_files(entry: dict, d: Path) -> None:
    """Check the files of an entry that pins a hash per file; a bad one is removed so a new run fetches it again."""
    sums = entry.get("sha256")
    if not isinstance(sums, dict):
        return
    for name, want in sums.items():
        if sha256(d / name) != want:
            (d / name).unlink(missing_ok=True)
            raise ValueError(f"{name}: checksum mismatch")


def ensure_model(data: Path, name: str, downloader: Downloader = hf_download) -> Path:
    """Download a model at its pinned revision, and the VAD: onnx models split speech by it, Whisper's lines
    without a voice under them are dropped by it."""
    if name not in models.MODELS:
        raise ValueError(f"unknown model {name!r}; available: {', '.join(models.MODELS)}")
    m = models.MODELS[name]
    d = models.model_dir(data, name)
    ensure_entry(m, d, downloader)
    ensure_entry(models.VAD, models.vad_dir(data), downloader)
    return d


def echo_model_intact(entry: dict, d: Path) -> bool:
    """The downloaded checkpoint matches the hash pinned in the manifest."""
    f = d / entry["files"][0]
    return f.is_file() and sha256(f) == entry["sha256"]


def ensure_echo_model(data: Path, downloader: Downloader = hf_download) -> None:
    """The neural echo suppressor's weights. Optional: without them the classic canceller is used. A bad copy is
    downloaded once more; a run that still fails leaves no .complete, so the next launch retries."""
    entry = models.MANIFEST.get("aec")
    if not entry:
        return
    d = Path(data) / "models" / entry["dir"]
    marker = EngineDir(Path(data)).no_echo_model
    for name in PREVIOUS_ECHO_DIRS:                      # a replaced checkpoint nothing reads any more
        if name != entry["dir"]:
            shutil.rmtree(Path(data) / "models" / name, ignore_errors=True)
    try:
        if (d / models.COMPLETE).exists() and echo_model_intact(entry, d):
            marker.unlink(missing_ok=True)
            return
        step(t("install_echo_model"))
        for attempt in range(2):
            if (d / models.COMPLETE).exists() and not echo_model_intact(entry, d):
                shutil.rmtree(d, ignore_errors=True)         # corrupted, or marked complete without a hash
            ensure_entry(entry, d, downloader)
            if echo_model_intact(entry, d):
                marker.unlink(missing_ok=True)
                return
            shutil.rmtree(d, ignore_errors=True)
        raise ValueError(f"{entry['files'][0]}: checksum mismatch")
    except Exception as ex:  # noqa: BLE001  the engine works without it
        marker.touch()
        print(t("install_no_echo_model", err=ex), flush=True)


def ensure_embedding_onnx(data: Path, fetch: Fetcher) -> None:
    """Windows: the faster speaker embeddings for the CPU. Optional: without this file the engine uses torch, so a failed
    download is not worth a message."""
    if platform_support.SYSTEM != "win32":
        return
    entry = models.MANIFEST["embedding_onnx"]
    d = Path(data) / "models" / entry["dir"]
    target = d / entry["file"]
    if target.is_file() and sha256(target) == entry["sha256"]:
        return
    temporary = target.with_suffix(".download")
    try:
        d.mkdir(parents=True, exist_ok=True)
        fetch(entry["url"], temporary)
        if sha256(temporary) == entry["sha256"]:
            platform_support.replace_file(temporary, target)
            (d / "NOTICE.txt").write_text(entry["notice"] + "\n", encoding="utf-8")
    except (OSError, subprocess.SubprocessError):
        pass
    finally:
        temporary.unlink(missing_ok=True)


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


def environment_hash(engine: EngineDir) -> str:
    """On Windows the GPU step replaces torch on top of the lock: both decide what the environment holds."""
    lock = sha256(engine.root / "uv.lock")
    if platform_support.SYSTEM != "win32":
        return lock[:16]
    overlay = windows_overlay(engine)
    if not overlay:
        return lock[:16]
    return hashlib.sha256((lock + sha256(overlay)).encode()).hexdigest()[:16]


def windows_overlay(engine: EngineDir) -> Path | None:
    """The requirements file of the installed GPU build, if the GPU step succeeded."""
    if not accel.gpu_configured():
        return None
    from . import gpu_probe
    state = accel._probe()
    for backend in gpu_probe.load_table():
        if backend["id"] == state.get("backend") and backend.get("requirements"):
            f = engine.root / "gpu" / backend["requirements"]
            return f if f.is_file() else None
    return None


def write_markers(engine: EngineDir) -> None:
    """Which uv.lock the environment was built from and when: the app uses this to decide on reinstall."""
    lock = engine.root / "uv.lock"
    if lock.exists():
        engine.venv_lock.write_text(environment_hash(engine) + "\n")
    engine.installed.write_text(f"{int(time.time())}\n")


def windows_default_model(engine: EngineDir, settings) -> str:
    """The model for this machine, unless the user chose one. A downloaded one is kept: nothing is removed or fetched on top
    of it. With a working GPU Whisper Turbo; on the CPU GigaAM for Russian, Parakeet for the rest, which beat real time
    even at low priority. Written to .env, so the engine uses the same one."""
    explicit = os.environ.get("SOZVON_MODEL") or config.read_env_file(engine.env_file).get("SOZVON_MODEL")
    if explicit and explicit in models.MODELS:
        return explicit
    chosen = next((name for name in models.MODELS if models.is_downloaded(engine.root, name)), None)
    if chosen is None and accel.gpu_configured():
        chosen = "turbo"
    if chosen is None:
        languages = [x.strip() for x in settings.languages.split(",") if x.strip()]
        chosen = "gigaam" if languages == ["ru"] else "parakeet"
    with open(engine.env_file, "a", encoding="utf-8") as f:
        f.write(f"SOZVON_MODEL={chosen}\n")
    return chosen


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
    if platform_support.SYSTEM == "win32":
        model = windows_default_model(engine, settings)
    step(t("install_model", model=model))
    ensure_model(engine.root, model, downloader)
    ru = models.ru_model(model, settings.model_ru)
    if ru:
        step(t("install_model", model=ru))
        ensure_model(engine.root, ru, downloader)

    ensure_echo_model(engine.root, downloader)
    ensure_embedding_onnx(engine.root, fetch)

    if not engine.pyannote_cache.is_dir():
        step(t("install_pyannote"))
        sources = pyannote_sources(os.environ.get("SOZVON_PYANNOTE_TAR"),
                                   os.environ.get("SOZVON_PYANNOTE_URL") or PYANNOTE_URL)
        if not install_pyannote(engine, sources, os.environ.get("SOZVON_PYANNOTE_SHA") or PYANNOTE_SHA, fetch):
            print(t("install_no_diarization"), flush=True)

    write_markers(engine)
    step(t("install_done"))
    return 0
