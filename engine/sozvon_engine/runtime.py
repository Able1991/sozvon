"""Окружение процесса движка. Вызывается в точках входа до импорта тяжёлых библиотек."""
import os

from . import config, paths


def prepare(offline: bool = True) -> None:
    """Офлайн Hugging Face, кэш моделей pyannote из установщика и предел потоков.

    offline: модели уже скачаны, при каждом запуске в сеть не ходим (установщик передаёт False).
    """
    os.environ.setdefault("HF_HUB_OFFLINE", "1" if offline else "0")
    cache = paths.engine_dir().hf_cache
    if cache.is_dir():
        os.environ.setdefault("HF_HUB_CACHE", str(cache))
    threads = config.load().threads
    if threads:
        # «Не мешать работе»: до импорта numpy, torch и onnxruntime, иначе пулы потоков уже созданы.
        for var in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
            os.environ.setdefault(var, str(threads))
