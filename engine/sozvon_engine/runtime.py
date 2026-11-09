"""Engine process environment. Called in entry points before heavy libraries are imported."""
import os

from . import config, paths, platform_support


def prepare(offline: bool = True) -> None:
    """Offline Hugging Face, the installer's pyannote model cache, and a thread limit.

    offline: models are already downloaded, so no network on each run (the installer passes False).
    """
    os.environ.setdefault("HF_HUB_OFFLINE", "1" if offline else "0")
    cache = paths.engine_dir().hf_cache
    if cache.is_dir():
        os.environ.setdefault("HF_HUB_CACHE", str(cache))
    if platform_support.SYSTEM == "win32":  # one limit for every library, also read by what this process starts
        os.environ.setdefault("SOZVON_THREADS", str(platform_support.default_thread_limit()))
    threads = config.load().threads
    platform_support.prepare_process()
    if threads:
        # "Stay out of the way": before importing numpy, torch and onnxruntime, or thread pools already exist.
        for var in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
            os.environ.setdefault(var, str(threads))
