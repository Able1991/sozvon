"""Which device the heavy models run on. The one place that decides, for torch and for Whisper.

macOS: exactly what the modules did themselves, mps if it is there. Windows: the decision of the install's probe
(<data>/.gpu.json); without it, or when anything goes wrong on the card, the CPU. A stage that fails on the GPU runs
again on the CPU and stays there for the rest of the process.
"""
import gc
import json
import sys

from . import config, paths, platform_support
from .i18n import t

_cpu_stages: set = set()
_GPU_ERRORS = (RuntimeError, ValueError)  # how torch and ctranslate2 report a missing library or no memory


def _windows() -> bool:
    return platform_support.SYSTEM == "win32"


def _probe() -> dict:
    """What the probe of the install found. Empty if it never ran or its file is broken."""
    try:
        state = json.loads((paths.data_dir() / ".gpu.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return state if isinstance(state, dict) else {}


def gpu_configured() -> bool:
    """Windows: the probe passed. Reads one file, so a CPU install never imports torch for this."""
    state = _probe()
    return state.get("ok") is True and state.get("device") == "cuda"


def torch_device(stage: str) -> str:
    """The device for a stage's torch model. Imports torch, which is also what loads the CUDA libraries."""
    import torch
    if not _windows():
        return "mps" if torch.backends.mps.is_available() else "cpu"
    if stage in _cpu_stages or not gpu_configured():
        return "cpu"
    return "cuda" if torch.cuda.is_available() else "cpu"


def apply_thread_limit() -> None:
    """The engine's one thread limit, for torch."""
    threads = config.load().threads
    if threads:
        import torch
        torch.set_num_threads(threads)


def note_failure(stage: str, error) -> None:
    """One log line and a marker, so the card can be probed again. The stage goes on on the CPU."""
    _cpu_stages.add(stage)
    print(t("log_gpu_stage_failed", stage=stage, err=" ".join(str(error).split())[:300]), file=sys.stderr, flush=True)
    try:
        (paths.data_dir() / ".gpu-failed").write_text(f"{stage}\n", encoding="utf-8")
    except OSError:
        pass


def with_cpu_fallback(stage: str, work, drop=None):
    """Run a stage; on Windows, a failure on the GPU runs it once more on the CPU. work asks torch_device itself and
    must start over from nothing. drop lets go of what the failed attempt holds, before its memory is released.
    On macOS a failure stays what it always was."""
    if not _windows():
        return work()
    on_gpu = torch_device(stage) == "cuda"
    try:
        return work()
    except _GPU_ERRORS as e:
        if not on_gpu:
            raise
        note_failure(stage, e)
        if drop:
            drop()
        release()
        return work()


def release() -> None:
    """Give the memory of a finished stage back to the card."""
    gc.collect()
    try:
        import torch
        if _windows():
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        elif torch.backends.mps.is_available():
            torch.mps.empty_cache()
    except Exception:  # noqa: BLE001  cleanup only
        pass
