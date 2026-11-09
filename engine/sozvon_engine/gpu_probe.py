"""The GPU step of the install: which card is this, which torch build goes with it, and does it really work.

The check runs in a process of its own with a time limit, because a bad driver can crash or hang whoever touches it. The
result is <data>/.gpu.json, the only thing the engine reads later (accel.py). Run by setup.ps1 -Gpu:
  python -m sozvon_engine.gpu_probe detect [--experimental]   prints the backend for this machine
  python -m sozvon_engine.gpu_probe verify <backend>          runs the check, writes .gpu.json
  python -m sozvon_engine.gpu_probe fail <backend> <reason>   records that the GPU step did not work
"""
import json
import re
import subprocess
import sys
import time
from pathlib import Path

from . import jsonfile, paths, platform_support

TABLE = paths.CODE_DIR / "gpu" / "backends.json"
TIMEOUT = 120  # seconds: a cold torch import with CUDA, on a slow disk under an antivirus


def load_table() -> list:
    return json.loads(TABLE.read_text(encoding="utf-8"))["backends"]


def nvidia_adapters() -> list:
    try:
        r = subprocess.run([platform_support.tool_path("nvidia-smi"), "--query-gpu=name,compute_cap,driver_version,memory.total",
                            "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return []
    if r.returncode != 0:
        return []
    out = []
    for line in r.stdout.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 4:
            out.append({"vendor": "nvidia", "name": parts[0], "compute_cap": parts[1], "driver": parts[2], "vram_mb": parts[3]})
    return out


def other_adapters() -> list:
    """The display adapters Windows knows of, for cards without nvidia-smi."""
    try:
        r = subprocess.run([platform_support.tool_path("powershell"), "-NoProfile", "-Command",
                            "(Get-CimInstance Win32_VideoController).Name"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return []
    return [{"vendor": "amd" if re.search("AMD|Radeon", n) else "other", "name": n.strip()} for n in r.stdout.splitlines() if n.strip()]


def matches(backend: dict, adapter: dict) -> bool:
    if backend["vendor"] != adapter["vendor"]:
        return False
    if "compute_cap" in backend:
        try:
            cap = float(adapter.get("compute_cap", ""))
        except ValueError:
            return False
        return backend["compute_cap"]["min"] <= cap <= backend["compute_cap"]["max"]
    return bool(re.search(backend["names"], adapter.get("name", "")))


def select(adapters: list, table: list, experimental: bool = False) -> tuple:
    """-> (backend, adapter), or (None, None) when nothing here can be used. NVIDIA first, then the rest."""
    for adapter in sorted(adapters, key=lambda a: a["vendor"] != "nvidia"):
        for backend in table:
            if matches(backend, adapter) and (experimental or not backend.get("experimental")):
                return backend, adapter
    return None, None


def is_tested(backend: dict, adapter: dict) -> bool:
    return adapter.get("compute_cap") in backend.get("tested", [])


def write_state(**state) -> None:
    jsonfile.write_atomic(paths.data_dir() / ".gpu.json", {**state, "probed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})


def check() -> dict:
    """Runs in the child process: a real computation on the card, compared with the same one on the CPU."""
    import torch
    if not torch.cuda.is_available():
        return {"ok": False, "reason": "torch sees no GPU"}
    torch.manual_seed(1)
    x = torch.rand(128, 128)
    expected = (x @ x).sum().item()
    got = (x.to("cuda") @ x.to("cuda")).sum().item()
    if abs(expected - got) > abs(expected) * 1e-3:
        return {"ok": False, "reason": f"the GPU computed {got}, the CPU {expected}"}
    import ctranslate2
    return {"ok": True, "device": "cuda", "torch": torch.__version__, "name": torch.cuda.get_device_name(0),
            "vram_mb": torch.cuda.get_device_properties(0).total_memory // (1 << 20), "ctranslate2_gpus": ctranslate2.get_cuda_device_count()}


def verify(backend: str, command=None) -> dict:
    """Run check() in a child process with a time limit; the outcome goes to .gpu.json."""
    command = command or [sys.executable, "-m", "sozvon_engine.gpu_probe", "child"]
    try:
        r = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=TIMEOUT)
        result = json.loads(r.stdout.strip().splitlines()[-1]) if r.returncode == 0 and r.stdout.strip() else None
        if not isinstance(result, dict):
            result = {"ok": False, "reason": f"the check ended with code {r.returncode}: {r.stderr[-300:]}"}
    except subprocess.TimeoutExpired:
        result = {"ok": False, "reason": f"the check did not finish in {TIMEOUT} s"}
    except (OSError, ValueError) as e:
        result = {"ok": False, "reason": str(e)}
    write_state(backend=backend, **result)
    return result


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    action = argv[0] if argv else ""
    if action == "child":
        print(json.dumps(check()), flush=True)
        return 0
    if action == "detect":
        backend, adapter = select(nvidia_adapters() + other_adapters(), load_table(), "--experimental" in argv)
        if backend is None or not backend.get("requirements"):
            print(f"none {adapter['name'] if adapter else ''}".strip(), flush=True)
            return 0
        note = "" if is_tested(backend, adapter) else " (not verified on this kind of card)"
        print(f"{backend['id']} {backend.get('index', '')} {backend['requirements']} {adapter['name']}{note}", flush=True)
        return 0
    if action == "verify":
        result = verify(argv[1])
        print(json.dumps(result, ensure_ascii=False), flush=True)
        return 0 if result.get("ok") else 1
    if action == "fail":
        write_state(backend=argv[1], ok=False, reason=" ".join(argv[2:]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
