"""The platform seam: everything in the engine that is specific to an operating system.

File locks, moving a folder to the Trash, the default data and calls folders, the folders where
user-installed command line tools live, and process-tree control. Other modules call these
functions and never import fcntl, osascript or "/opt/homebrew" themselves.

macOS is implemented here; Windows lives in platform_win32.py, imported only inside the win32 branches.
(Named platform_support so it never shadows the stdlib `platform`.) The Whisper/mlx backends are a
separate seam in whisper.py.
"""
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

SYSTEM = sys.platform  # "darwin", "win32", "linux" (behaves like POSIX where it can)

# Stage 1 on Windows: a call's text is untrusted, and the sandboxes of these assistants could not be checked there.
UNVERIFIED_ASSISTANTS = ("codex", "cursor") if SYSTEM == "win32" else ()
# Project discovery lets an assistant read files; its read-only rules have no equivalent on Windows yet.
AGENTIC_OFF = SYSTEM == "win32"
# For text=True pipes to a command line tool. On Windows stderr can come in the console code page.
TEXT_MODE = {"encoding": "utf-8", "errors": "replace"} if SYSTEM == "win32" else {"encoding": "utf-8"}


# --- default folders and tool directories ---

def default_data_dir() -> Path:
    """Engine data folder when neither SOZVON_DATA_DIR nor the repo layout decides."""
    if SYSTEM == "win32":
        from . import platform_win32
        return platform_win32.default_data_dir()
    return Path.home() / "Library" / "Application Support" / "Sozvon"


def default_calls_dir() -> Path:
    """Where call folders live when SOZVON_CALLS_DIR is not set."""
    if SYSTEM == "win32":
        from . import platform_win32
        return platform_win32.default_calls_dir()
    return Path.home() / "Documents" / "Calls"


def tool_bin_dirs() -> list[Path]:
    """Extra folders to look for user-installed CLIs (claude, codex...) when they are not on PATH,
    as happens for an app launched from the Dock."""
    if SYSTEM == "win32":
        return [Path.home() / ".local" / "bin"]
    return [Path.home() / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin")]


# --- programs the engine starts ---

def tool_path(name: str) -> str:
    """What to start for an external program. On Windows an absolute path, FileNotFoundError if it is absent."""
    if SYSTEM == "win32":
        from . import platform_win32
        return platform_win32.tool_path(name)
    return name


def find_cli(name: str, extra_dirs) -> str | None:
    """Windows: an assistant's command line tool that can be started safely, by absolute path."""
    from . import platform_win32
    return platform_win32.find_cli(name, extra_dirs)


def cli_argv(path: str) -> list:
    """The start of the command line for a tool found on this machine."""
    if SYSTEM == "win32":
        from . import platform_win32
        return platform_win32.cli_argv(path)
    return [path]


def prepare_process() -> None:
    """What an engine process sets up about itself. Nothing on macOS, where the app does it."""
    if SYSTEM == "win32":
        from . import platform_win32
        platform_win32.prepare_process()


def default_thread_limit() -> int:
    """Half of the logical cores: on Windows faster than all of them, and the computer stays usable."""
    return max(1, (os.cpu_count() or 2) // 2)


# --- file locks (advisory, released by the OS when the process dies) ---

def lock_exclusive(fd: int, wait: bool = True) -> bool:
    """Exclusive flock on an open descriptor. wait=False: return False instead of blocking if it is held."""
    if SYSTEM == "win32":
        from . import platform_win32
        return platform_win32.lock_exclusive(fd, wait)
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
        from . import platform_win32
        platform_win32.unlock(fd)
        return
    import fcntl
    fcntl.flock(fd, fcntl.LOCK_UN)


def open_call_lock(folder: Path) -> int:
    """The descriptor to take lock_exclusive on for "one run on this call"; close it to release."""
    if SYSTEM == "win32":
        from . import paths, platform_win32
        return platform_win32.open_call_lock(folder, paths.data_dir() / "locks")
    return os.open(folder, os.O_RDONLY)


# --- processes ---

def parent_pid() -> int:
    """PID of the parent (the app). Changes when the parent dies."""
    if SYSTEM == "win32":
        from . import platform_win32
        return platform_win32.parent_pid()
    return os.getppid()


def bind_workers_to_process() -> bool:
    """Make the workers of this process die with it, however it dies. On macOS the app's process group does that."""
    if SYSTEM == "win32":
        from . import platform_win32
        return platform_win32.bind_workers_to_process()
    return False


def owns_process_group() -> bool:
    """Whether kill_own_process_group would take only this engine and its workers."""
    if SYSTEM == "win32":
        from . import platform_win32
        return platform_win32.owns_process_group()
    return os.getpgrp() == os.getpid()


def kill_own_process_group() -> None:
    """SIGKILL the whole process group of this process (the engine and its workers)."""
    if SYSTEM == "win32":
        from . import platform_win32
        platform_win32.kill_own_process_group()
        return
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
        # TODO before sync is turned on for Windows: a folder larger than the Recycle Bin quota is deleted for good
        # without a word, and sync calls this for calls deleted on another machine. It needs a guard against that,
        # for example moving such a deletion to a <data>/trash folder.
        from . import platform_win32
        platform_win32.move_to_trash(Path(path))
        return
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
