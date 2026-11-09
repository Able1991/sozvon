"""The platform seam: the one place that knows about macOS (locks, Trash, default folders, bin dirs)."""
import os
import subprocess
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


def test_windows_is_explicitly_unsupported_for_locks_and_trash(monkeypatch, tmp_path):
    monkeypatch.setattr(ps, "SYSTEM", "win32")
    fd = os.open(tmp_path, os.O_RDONLY)
    try:
        with pytest.raises(NotImplementedError):
            ps.lock_exclusive(fd)
        with pytest.raises(NotImplementedError):
            ps.unlock(fd)
    finally:
        os.close(fd)
    with pytest.raises(NotImplementedError):
        ps.move_to_trash(tmp_path)
    with pytest.raises(NotImplementedError):
        ps.kill_own_process_group()


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
