"""Engine process environment. Called in entry points before heavy libraries are imported."""
import os

from . import config, paths


def prepare(offline: bool = True) -> None:
    """Offline Hugging Face, the installer's pyannote model cache, and a thread limit.

    offline: models are already downloaded, so no network on each run (the installer passes False).
    """
    os.environ.setdefault("HF_HUB_OFFLINE", "1" if offline else "0")
    cache = paths.engine_dir().hf_cache
    if cache.is_dir():
        os.environ.setdefault("HF_HUB_CACHE", str(cache))
    threads = config.load().threads
    if threads:
        # "Stay out of the way": before importing numpy, torch and onnxruntime, or thread pools already exist.
        for var in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
            os.environ.setdefault(var, str(threads))
