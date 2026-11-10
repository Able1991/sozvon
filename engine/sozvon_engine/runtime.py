"""Engine process environment. Called in entry points before heavy libraries are imported."""
import os

from . import config, paths, platform_support


# Network keys a corporate network may need (docs/CORPORATE.md). An app opened from Finder
# does not see the shell environment, so they can also be written into .env in the data folder.
NETWORK_KEYS = ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "HF_ENDPOINT",
                "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "SOZVON_SYSTEM_CERTS")


def network_env() -> None:
    """Network keys from .env into the process environment (the environment wins), then
    the system certificate store (macOS Keychain) for every HTTPS client in the process,
    so a company root certificate is trusted without exporting it.
    An explicit certificate file, or SOZVON_SYSTEM_CERTS=0, keeps Python's own store."""
    file_vals = config.read_env_file(paths.engine_dir().env_file)
    for k in NETWORK_KEYS:
        v = file_vals.get(k, "").strip()
        if v:
            os.environ.setdefault(k, v)
    # requests reads REQUESTS_CA_BUNDLE, httpx and ssl read SSL_CERT_FILE: one is enough to set.
    for a, b in (("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"), ("REQUESTS_CA_BUNDLE", "SSL_CERT_FILE")):
        if os.environ.get(a) and not os.environ.get(b):
            os.environ[b] = os.environ[a]
    if os.environ.get("SSL_CERT_FILE") or os.environ.get("SOZVON_SYSTEM_CERTS", "").strip().lower() in {"0", "false", "no", "off"}:
        return
    try:
        import truststore
        truststore.inject_into_ssl()
    except Exception:  # noqa: BLE001 - no truststore or an old macOS: Python's own store, as before
        pass


def prepare(offline: bool = True) -> None:
    """Network settings, offline Hugging Face, the installer's pyannote model cache, and a thread limit.

    offline: models are already downloaded, so no network on each run (the installer passes False).
    """
    network_env()
    os.environ.setdefault("HF_HUB_OFFLINE", "1" if offline else "0")
    cache = paths.engine_dir().hf_cache
    if cache.is_dir():
        os.environ.setdefault("HF_HUB_CACHE", str(cache))
    if platform_support.SYSTEM == "win32":  # one limit for every library, also read by what this process starts
        os.environ.setdefault("SOZVON_THREADS", str(platform_support.default_thread_limit()))
    threads = config.load().threads
    platform_support.prepare_process()
    platform_support.bind_workers_to_process()
    if threads:
        # "Stay out of the way": before importing numpy, torch and onnxruntime, or thread pools already exist.
        for var in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
            os.environ.setdefault(var, str(threads))
