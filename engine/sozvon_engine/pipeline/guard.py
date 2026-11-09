"""One engine on one call: what a crash of the app must not break.

After a crash the app relaunches and requeues the call it was transcribing, while the old engine may still be in a
long Whisper or pyannote stage (it only notices the closed pipe at its next log line). So the engine dies with the
app, and a run holds a lock on the call folder until it ends: the lock goes away with the process, however it dies.
"""
import os
import signal
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path

from .. import platform_support
from ..i18n import t


def watch_parent(interval: float = 2.0) -> None:
    """Exit, with the workers (ffmpeg, an assistant), once the parent is gone. Nothing to watch if it already was."""
    parent = platform_support.parent_pid()
    if parent == 1:
        return

    def loop():
        while platform_support.parent_pid() == parent:
            time.sleep(interval)
        if platform_support.owns_process_group():  # the app starts the engine as the leader of its own group
            platform_support.kill_own_process_group()
        os._exit(1)

    threading.Thread(target=loop, daemon=True).start()


def exit_on_sigterm() -> None:
    """SIGTERM (the app stopping a run) ends the run through its `finally` blocks, so the working files go too.
    Exit code 143, as for any process killed by SIGTERM. Only the main thread can install it.

    Windows has no SIGTERM between processes, so CTRL_BREAK stands in for it. CTRL_BREAK reaches only a process started
    with CREATE_NEW_PROCESS_GROUP that shares the sender's console, and an app with windows has no console: such an app
    creates a named event and passes its name in SOZVON_STOP_EVENT, and signalling it does the same as CTRL_BREAK. Either
    way the stop waits until the main thread is back in Python: it is delayed while native code or time.sleep runs."""
    def handler(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, handler)
    if platform_support.SYSTEM == "win32":
        signal.signal(signal.SIGBREAK, lambda signum, frame: handler(signal.SIGTERM, frame))
        _stop_on_named_event(os.environ.get("SOZVON_STOP_EVENT"))


def _stop_on_named_event(name: str | None) -> None:
    """Windows: a thread waits on the event the app gave and raises the stop signal in this process. No name, no thread."""
    if not name:
        return

    def wait():
        if platform_support.wait_for_named_event(name):
            signal.raise_signal(signal.SIGBREAK)
        else:
            print(t("log_stop_event_failed", name=name), file=sys.stderr, flush=True)

    threading.Thread(target=wait, daemon=True).start()


def lock_call(d: Path, on_wait: Callable[[], None] = lambda: None) -> int:
    """Wait for any other run on this call to end; returns the descriptor to close when this run ends.

    The folder itself is locked: no extra file in it, and a rename does not matter.
    """
    fd = platform_support.open_call_lock(d)
    if not platform_support.lock_exclusive(fd, wait=False):
        on_wait()
        platform_support.lock_exclusive(fd)
    return fd
