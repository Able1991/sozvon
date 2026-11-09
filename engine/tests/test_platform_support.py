"""The platform seam: the one place that knows about macOS (locks, Trash, default folders, bin dirs)."""
import os
import subprocess
import sys
from pathlib import Path

import pytest

from sozvon_engine import platform_support as ps


def test_module_does_not_shadow_stdlib():
    import platform
    assert hasattr(platform, "system")


def test_default_folders_macos(monkeypatch):
    monkeypatch.setattr(ps, "SYSTEM", "darwin")
    assert ps.default_data_dir() == Path.home() / "Library" / "Application Support" / "Sozvon"
    assert ps.default_calls_dir() == Path.home() / "Documents" / "Calls"


def test_tool_bin_dirs_macos(monkeypatch):
    monkeypatch.setattr(ps, "SYSTEM", "darwin")
    assert ps.tool_bin_dirs() == [Path.home() / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin")]


@pytest.mark.skipif(sys.platform == "win32", reason="a folder cannot be opened as a file on Windows (test_platform_win32.py)")
def test_lock_exclusive_nonblocking_reports_contention(tmp_path):
    a = os.open(tmp_path, os.O_RDONLY)
    b = os.open(tmp_path, os.O_RDONLY)
    try:
        assert ps.lock_exclusive(a) is True
        assert ps.lock_exclusive(b, wait=False) is False
        ps.unlock(a)
        assert ps.lock_exclusive(b, wait=False) is True
        ps.unlock(b)
    finally:
        os.close(a)
        os.close(b)


def test_parent_pid_is_getppid():
    assert ps.parent_pid() == os.getppid()


@pytest.mark.skipif(sys.platform == "win32", reason="the macOS Trash (test_platform_win32.py has the Recycle Bin)")
def test_trash_fallback_moves_to_dot_trash(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    (tmp_path / "home").mkdir()
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: subprocess.CompletedProcess(a, 1, "", ""))
    d = tmp_path / "call"
    d.mkdir()
    (d / "x").write_text("1")
    ps.move_to_trash(d)
    assert not d.exists()
    assert (tmp_path / "home" / ".Trash" / "call" / "x").read_text() == "1"
