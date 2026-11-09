"""The platform seam: everything in the engine that is specific to an operating system.

File locks, moving a folder to the Trash, the default data and calls folders, the folders where
user-installed command line tools live, and process-tree control. Other modules call these
functions and never import fcntl, osascript or "/opt/homebrew" themselves.

Only macOS is implemented. The Windows branches either use the obvious stdlib path or raise
NotImplementedError with a clear message, so a port has one place to fill in. (Named
platform_support so it never shadows the stdlib `platform`.) The Whisper/mlx backends are a
separate seam in whisper.py.
"""
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

SYSTEM = sys.platform  # "darwin" (supported), "win32" (not yet), "linux" (behaves like POSIX where it can)


def _unsupported(what: str) -> NotImplementedError:
    return NotImplementedError(f"{what} is not implemented for platform {SYSTEM!r} yet")


# --- default folders and tool directories ---

def default_data_dir() -> Path:
    """Engine data folder when neither SOZVON_DATA_DIR nor the repo layout decides."""
    if SYSTEM == "win32":
        base = os.environ.get("APPDATA")
        return (Path(base) if base else Path.home() / "AppData" / "Roaming") / "Sozvon"
    return Path.home() / "Library" / "Application Support" / "Sozvon"


def default_calls_dir() -> Path:
    """Where call folders live when SOZVON_CALLS_DIR is not set."""
    return Path.home() / "Documents" / "Calls"


def tool_bin_dirs() -> list[Path]:
    """Extra folders to look for user-installed CLIs (claude, codex...) when they are not on PATH,
    as happens for an app launched from the Dock."""
    if SYSTEM == "win32":
        return [Path.home() / ".local" / "bin"]
    return [Path.home() / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin")]


# --- file locks (advisory, released by the OS when the process dies) ---

def lock_exclusive(fd: int, wait: bool = True) -> bool:
    """Exclusive flock on an open descriptor. wait=False: return False instead of blocking if it is held."""
    if SYSTEM == "win32":
        raise _unsupported("file locking")
    import fcntl
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
    except BlockingIOError:
        if wait:
            raise
        return False
    return True


def unlock(fd: int) -> None:
    if SYSTEM == "win32":
        raise _unsupported("file locking")
    import fcntl
    fcntl.flock(fd, fcntl.LOCK_UN)


# --- processes ---

def parent_pid() -> int:
    """PID of the parent (the app). Changes when the parent dies."""
    return os.getppid()


def kill_own_process_group() -> None:
    """SIGKILL the whole process group of this process (the engine and its workers)."""
    if SYSTEM == "win32":
        raise _unsupported("killing a process group")
    os.killpg(0, signal.SIGKILL)


# --- the Trash ---

# No Ref() out-parameters: on current macOS a Ref for the NSError crashes osascript (signal 11).
_JXA_TRASH = """
ObjC.import("Foundation");
function run(argv) {
  const ok = $.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError(
    $.NSURL.fileURLWithPath(argv[0]), null, null);
  return ok ? "ok" : "failed";
}
"""


def move_to_trash(path: Path) -> None:
    """Move a folder to the macOS Trash, like Finder (Put Back works): NSFileManager.trashItem through
    osascript's ObjC bridge. If that fails, a plain move to ~/.Trash under a free name."""
    if SYSTEM == "win32":
        raise _unsupported("moving to the Recycle Bin")
    path = Path(path)
    try:
        r = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", _JXA_TRASH, str(path)],
                           check=False, capture_output=True, text=True, timeout=30)
        if r.returncode == 0 and r.stdout.strip() == "ok" and not path.exists():
            return
    except (OSError, subprocess.SubprocessError):
        pass
    trash = Path.home() / ".Trash"
    trash.mkdir(exist_ok=True)
    target = trash / path.name
    n = 1
    while target.exists():
        target = trash / (f"{path.name} {time.strftime('%H.%M.%S')}" + (f" {n}" if n > 1 else ""))
        n += 1
    shutil.move(str(path), str(target))
