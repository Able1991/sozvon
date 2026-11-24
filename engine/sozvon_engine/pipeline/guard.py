"""One engine on one call: what a crash of the app must not break.

After a crash the app relaunches and requeues the call it was transcribing, while the old engine may still be in a
long Whisper or pyannote stage (it only notices the closed pipe at its next log line). So the engine dies with the
app, and a run holds a lock on the call folder until it ends: the lock goes away with the process, however it dies.
"""
import contextlib
import os
import signal
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path

from .. import platform_support


# Held while a run commits a change that must not stop halfway (trim: the renames and the call.json write).
_commit = threading.Lock()


@contextlib.contextmanager
def committing() -> Iterator[None]:
    """A step that must finish once begun: the parent watcher waits for it before it exits, and a SIGTERM that comes
    meanwhile takes effect (SystemExit 143) only when the step is done. SIGKILL still kills; outside the main thread
    (where no signal handler can be set) only the watcher waits."""
    pending: list[int] = []
    old = None
    with _commit:
        if threading.current_thread() is threading.main_thread():
            old = signal.signal(signal.SIGTERM, lambda signum, frame: pending.append(signum))
        try:
            yield
        finally:
            if old is not None:
                signal.signal(signal.SIGTERM, old)
    if pending:
        raise SystemExit(128 + pending[0])


def watch_parent(interval: float = 2.0) -> None:
    """Exit, with the workers (ffmpeg, an assistant), once the parent is gone. Nothing to watch if it already was.
    A step in committing() finishes first."""
    parent = platform_support.parent_pid()
    if parent == 1:
        return

    def loop():
        while platform_support.parent_pid() == parent:
            time.sleep(interval)
        _commit.acquire()  # never released: the process ends here
        if os.getpgrp() == os.getpid():  # the app starts the engine as the leader of its own group
            platform_support.kill_own_process_group()
        os._exit(1)

    threading.Thread(target=loop, daemon=True).start()


def exit_on_sigterm() -> None:
    """SIGTERM (the app stopping a run) ends the run through its `finally` blocks, so the working files go too.
    Exit code 143, as for any process killed by SIGTERM. Only the main thread can install it."""
    def handler(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, handler)


def lock_call(d: Path, on_wait: Callable[[], None] = lambda: None) -> int:
    """Wait for any other run on this call to end; returns the descriptor to close when this run ends.

    The folder itself is locked: no extra file in it, and a rename does not matter.
    """
    fd = os.open(d, os.O_RDONLY)
    if not platform_support.lock_exclusive(fd, wait=False):
        on_wait()
        platform_support.lock_exclusive(fd)
    return fd
