"""The Windows side of the platform seam: locks, the parent watchdog, the worker Job Object, stop signal, Recycle Bin.

Real processes wherever the behaviour is about processes. The Recycle Bin call is replaced, so tests leave nothing there.
"""
import ctypes
import os
import re
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest

from sozvon_engine import platform_support as ps

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Windows only")

ENGINE_ROOT = Path(ps.__file__).resolve().parents[1]
IN_VENV = sys.prefix != sys.base_prefix
BASE_PYTHON = getattr(sys, "_base_executable", sys.executable)


def spawn(code: str, *args, exe=sys.executable, stdout=subprocess.PIPE, **kw) -> subprocess.Popen:
    env = {**os.environ, "PYTHONPATH": str(ENGINE_ROOT), "PYTHONUTF8": "1"}
    return subprocess.Popen([exe, "-c", textwrap.dedent(code), *map(str, args)], stdout=stdout, text=True, env=env, **kw)


def wait_for(check, timeout: float = 10.0) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if check():
            return True
        time.sleep(0.05)
    return False


def lines_of(path: Path) -> list:
    try:
        return path.read_text(encoding="utf-8").split()
    except OSError:
        return []


def pid_alive(pid: int) -> bool:
    r = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH", "/FO", "CSV"], capture_output=True, text=True, errors="replace")
    return f'"{pid}"' in r.stdout


def kill_pid(pid: int) -> None:
    subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)


@pytest.fixture
def win32():
    from sozvon_engine import platform_win32
    return platform_win32


@pytest.fixture
def lock_file(tmp_path):
    return tmp_path / "x.lock"


@pytest.fixture
def fd(lock_file):
    fd = os.open(lock_file, os.O_RDWR | os.O_CREAT, 0o600)
    yield fd
    os.close(fd)


# ---- file locks ----

TRY_LOCK = """
    import os, sys
    from sozvon_engine import platform_support as ps
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
    print(ps.lock_exclusive(fd, wait=False), flush=True)
"""


def test_lock_excludes_another_process(fd, lock_file):
    assert ps.lock_exclusive(fd) is True
    p = spawn(TRY_LOCK, lock_file)
    assert p.communicate(timeout=30)[0].strip() == "False"
    ps.unlock(fd)
    p = spawn(TRY_LOCK, lock_file)
    assert p.communicate(timeout=30)[0].strip() == "True"


def test_lock_excludes_another_descriptor_in_this_process(fd, lock_file):
    other = os.open(lock_file, os.O_RDWR)
    try:
        assert ps.lock_exclusive(fd) is True
        assert ps.lock_exclusive(other, wait=False) is False
        ps.unlock(fd)
        assert ps.lock_exclusive(other, wait=False) is True
        ps.unlock(other)
    finally:
        os.close(other)


def test_waiting_lock_waits_until_it_gets_the_lock(fd, lock_file):
    assert ps.lock_exclusive(fd) is True
    p = spawn("""
        import os, sys, time
        from sozvon_engine import platform_support as ps
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
        print("waiting", flush=True)
        start = time.time()
        got = ps.lock_exclusive(fd)
        print(got, round(time.time() - start, 2), flush=True)
    """, lock_file)
    assert p.stdout.readline().strip() == "waiting"
    time.sleep(1.0)
    assert p.poll() is None, "it must still be waiting"
    ps.unlock(fd)
    got, waited = p.communicate(timeout=30)[0].split()
    assert got == "True" and float(waited) >= 0.5


def test_unlock_without_a_lock_is_harmless(fd):
    ps.unlock(fd)  # jsonfile.locked() unlocks in `finally`, as flock allows


def test_lock_goes_away_with_the_process(fd, lock_file):
    p = spawn("""
        import os, sys, time
        from sozvon_engine import platform_support as ps
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
        ps.lock_exclusive(fd)
        print("held", flush=True)
        time.sleep(60)
    """, lock_file)
    assert p.stdout.readline().strip() == "held"
    assert ps.lock_exclusive(fd, wait=False) is False
    kill_pid(p.pid)
    p.wait(timeout=30)
    assert wait_for(lambda: ps.lock_exclusive(fd, wait=False))
    ps.unlock(fd)


# ---- the lock of a call folder ----

def test_call_lock_lives_outside_the_call_and_survives_a_rename(monkeypatch, tmp_path):
    data = tmp_path / "data"
    monkeypatch.setenv("SOZVON_DATA_DIR", str(data))
    d = tmp_path / "2026-11-04 15-01"
    d.mkdir()
    a = ps.open_call_lock(d)
    try:
        assert ps.lock_exclusive(a, wait=False) is True
        assert [p.name for p in (data / "locks").iterdir()] == ["2026-11-04 15-01.lock"], "created at first use"
        assert list(d.iterdir()) == [], "nothing is added to the call"
        renamed = d.with_name("2026-11-04 15-01 · Acme · запуск")
        d.rename(renamed)  # possible only with no open handle inside the folder
        b = ps.open_call_lock(renamed)
        try:
            assert ps.lock_exclusive(b, wait=False) is False, "the same call after its rename"
        finally:
            os.close(b)
    finally:
        os.close(a)


def test_different_calls_do_not_share_a_lock(monkeypatch, tmp_path):
    monkeypatch.setenv("SOZVON_DATA_DIR", str(tmp_path / "data"))
    (tmp_path / "2026-11-04 15-01").mkdir()
    (tmp_path / "2026-11-04 15-01-2 · Acme").mkdir()
    a = ps.open_call_lock(tmp_path / "2026-11-04 15-01")
    b = ps.open_call_lock(tmp_path / "2026-11-04 15-01-2 · Acme")
    try:
        assert ps.lock_exclusive(a, wait=False) is True
        assert ps.lock_exclusive(b, wait=False) is True
    finally:
        os.close(a)
        os.close(b)


# ---- the parent watchdog ----

CHILD = """
    import os, sys, time
    from sozvon_engine import platform_support as ps
    time.sleep(float(sys.argv[1]))
    first = ps.parent_pid()
    print("engine", os.getpid(), flush=True)
    print("first", first == os.getppid(), first != 1, flush=True)
    for _ in range(int(sys.argv[2])):
        if ps.parent_pid() != first:
            print("changed", ps.parent_pid(), flush=True)
            break
        time.sleep(0.05)
    else:
        print("stable", flush=True)
"""

# The parent of CHILD: starts it, says so, then lives on or leaves at once.
PARENT = """
    import os, subprocess, sys, time
    exe, child, delay, rounds, stays = sys.argv[1:6]
    env = dict(os.environ)
    c = subprocess.Popen([exe, "-c", child, delay, rounds], env=env)
    print("parent-up", c.pid, flush=True)
    if stays == "1":
        time.sleep(120)
"""


def _family(tmp_path, child_exe, delay, rounds, stays):
    out = tmp_path / "out.txt"
    f = open(out, "w", encoding="utf-8")
    p = spawn(PARENT, child_exe, textwrap.dedent(CHILD), delay, rounds, stays, exe=BASE_PYTHON, stdout=f)
    return p, f, out


@pytest.fixture
def cleanup():
    procs = []
    yield procs
    for pid in procs:
        kill_pid(pid)


def _child_pid(out: Path) -> int:
    assert wait_for(lambda: "parent-up" in lines_of(out))
    words = lines_of(out)
    return int(words[words.index("parent-up") + 1])


def _ready(out: Path) -> bool:
    return "first" in lines_of(out)


def test_parent_death_is_noticed_with_a_plain_python(tmp_path, cleanup):
    """No launcher: the watched process is the direct parent, not one step further up (this test process is alive)."""
    p, f, out = _family(tmp_path, BASE_PYTHON, 0, 400, "1")
    cleanup += [p.pid, _child_pid(out)]
    assert wait_for(lambda: _ready(out), 30)
    assert lines_of(out)[-3:] == ["first", "True", "True"]
    kill_pid(p.pid)
    p.wait(timeout=30)
    assert wait_for(lambda: "changed" in lines_of(out), 15)
    assert lines_of(out)[-1] == "1"
    f.close()


@pytest.mark.skipif(not IN_VENV, reason="needs the .venv launcher")
def test_death_above_the_venv_launcher_is_noticed(tmp_path, cleanup):
    """.venv\\Scripts\\python.exe is a launcher that lives as long as the engine: the app is one step above it."""
    p, f, out = _family(tmp_path, sys.executable, 0, 400, "1")
    cleanup += [p.pid, _child_pid(out)]
    assert wait_for(lambda: _ready(out), 30)
    kill_pid(p.pid)
    p.wait(timeout=30)
    assert wait_for(lambda: "changed" in lines_of(out), 15)
    assert lines_of(out)[-1] == "1"
    f.close()


def test_living_parent_gives_no_false_alarm(tmp_path, cleanup):
    p, f, out = _family(tmp_path, BASE_PYTHON, 0, 40, "1")
    cleanup += [p.pid, _child_pid(out)]
    assert wait_for(lambda: "stable" in lines_of(out) or "changed" in lines_of(out), 30)
    assert "stable" in lines_of(out)
    f.close()


def _gone_from_the_start(out: Path) -> None:
    assert wait_for(lambda: "stable" in lines_of(out) or "changed" in lines_of(out), 30)
    words = lines_of(out)
    assert "stable" in words, "the first reading stays"
    assert words[words.index("first") + 2] == "False", "an orphan reads as 1, as on macOS"


def test_parent_already_gone_at_start_is_not_a_death(tmp_path, cleanup):
    """A launch from a short-lived shell."""
    p, f, out = _family(tmp_path, BASE_PYTHON, 1.5, 40, "0")
    cleanup.append(_child_pid(out))
    p.wait(timeout=30)
    _gone_from_the_start(out)
    f.close()


@pytest.mark.skipif(not IN_VENV, reason="needs the .venv launcher")
def test_parent_of_the_launcher_already_gone_at_start_is_not_a_death(tmp_path, cleanup):
    p, f, out = _family(tmp_path, sys.executable, 1.5, 40, "0")
    cleanup.append(_child_pid(out))
    p.wait(timeout=30)
    _gone_from_the_start(out)
    f.close()


@pytest.mark.skipif(not IN_VENV, reason="needs the .venv launcher")
def test_a_killed_launcher_counts_as_the_death_of_the_parent(tmp_path, cleanup):
    """The app stops its child, which is the launcher: the engine must not go on alone. The launcher normally takes
    the engine with it through its own Job; otherwise the watchdog has to see it."""
    p, f, out = _family(tmp_path, sys.executable, 0, 400, "1")
    launcher = _child_pid(out)
    cleanup += [p.pid, launcher]
    assert wait_for(lambda: _ready(out), 30)
    words = lines_of(out)
    engine = int(words[words.index("engine") + 1])
    cleanup.append(engine)
    assert engine != launcher and pid_alive(engine)
    kill_pid(launcher)
    assert wait_for(lambda: "changed" in lines_of(out) or not pid_alive(engine), 15)
    assert p.poll() is None, "the parent itself is alive"
    f.close()


def test_a_parent_that_may_not_be_opened_is_not_a_death(monkeypatch, win32):
    def denied(*a):
        ctypes.set_last_error(5)  # ERROR_ACCESS_DENIED
        return None

    monkeypatch.setattr(win32._kernel32, "OpenProcess", denied)
    monkeypatch.setattr(win32, "_watch_ready", False)
    monkeypatch.setattr(win32, "_watches", [])
    monkeypatch.setattr(win32, "_gone_at_start", False)
    assert win32.parent_pid() == os.getppid()


# The engine's real watchdog around a piece of work. guard.watch_parent exits the process if it fires.
WATCHED_RUN = """
    import sys, time
    from sozvon_engine import platform_support as ps
    from sozvon_engine.pipeline import guard
    time.sleep(float(sys.argv[1]))
    guard.watch_parent(interval=0.05)
    print("first", ps.parent_pid() == 1, flush=True)
    time.sleep(int(sys.argv[2]) * 0.05)
    print("finished", flush=True)
"""


def _watched_family(tmp_path, delay, rounds, stays, child_exe=BASE_PYTHON):
    out = tmp_path / "out.txt"
    f = open(out, "w", encoding="utf-8")
    p = spawn(PARENT, child_exe, textwrap.dedent(WATCHED_RUN), delay, rounds, stays, exe=BASE_PYTHON, stdout=f)
    return p, f, out


@pytest.mark.parametrize("child_exe", [BASE_PYTHON, pytest.param(sys.executable, id="launcher")])
def test_a_run_started_as_an_orphan_goes_to_the_end(tmp_path, cleanup, child_exe):
    """parent == 1 from the very start: the watchdog must leave the transcription alone until it finishes."""
    p, f, out = _watched_family(tmp_path, 1.5, 60, "0", child_exe)
    cleanup.append(_child_pid(out))
    p.wait(timeout=30)
    assert wait_for(lambda: "finished" in lines_of(out), 30), lines_of(out)
    words = lines_of(out)
    assert words[words.index("first") + 1] == "True"
    f.close()


def test_the_watchdog_ends_the_run_when_the_parent_dies(tmp_path, cleanup):
    p, f, out = _watched_family(tmp_path, 0, 600, "1")
    engine = _child_pid(out)
    cleanup += [p.pid, engine]
    assert wait_for(lambda: "first" in lines_of(out), 30)
    assert lines_of(out)[-1] == "False", "the parent is alive"
    kill_pid(p.pid)
    p.wait(timeout=30)
    assert wait_for(lambda: not pid_alive(engine), 15), "the engine must go with its parent"
    assert "finished" not in lines_of(out)
    f.close()


# ---- workers die with the engine ----

WORKER = "import time; time.sleep(120)"

ENGINE = """
    import subprocess, sys, time
    from sozvon_engine import platform_support as ps
    print("bound", ps.bind_workers_to_process(), flush=True)
    w = subprocess.Popen([sys.executable, "-c", sys.argv[1]])
    print("worker", w.pid, flush=True)
    time.sleep(120)
"""


def _read_engine(p):
    bound = p.stdout.readline().split()
    worker = p.stdout.readline().split()
    return bound[1], int(worker[1])


def test_workers_die_with_the_engine_but_a_separate_process_does_not(cleanup):
    """The MCP server is started separately by the app: a transcription ending must not take it along."""
    sibling = spawn(WORKER)
    engine = spawn(ENGINE, WORKER)
    bound, worker = _read_engine(engine)
    cleanup += [sibling.pid, engine.pid, worker]
    assert bound == "True"
    assert pid_alive(worker)
    kill_pid(engine.pid)
    engine.wait(timeout=30)
    assert wait_for(lambda: not pid_alive(worker), 15), "the worker must not outlive the engine"
    assert sibling.poll() is None, "a process outside the engine's Job must live on"


def test_engine_binds_its_workers_inside_a_job_of_the_app(cleanup):
    """Stage 2 may hold the engine in its own Job: nesting works, and killing the engine leaves the app's Job alone."""
    app = spawn("""
        import subprocess, sys, time
        from sozvon_engine import platform_support as ps
        print("bound", ps.bind_workers_to_process(), flush=True)
        import os
        e = subprocess.Popen([sys.executable, "-c", sys.argv[1], sys.argv[2]], stdout=subprocess.PIPE, text=True, env=os.environ)
        print(e.stdout.readline().strip(), flush=True)
        print(e.stdout.readline().strip(), flush=True)
        print("engine", e.pid, flush=True)
        time.sleep(120)
    """, textwrap.dedent(ENGINE), WORKER)
    assert app.stdout.readline().split() == ["bound", "True"]
    inner = app.stdout.readline().split()
    worker = int(app.stdout.readline().split()[1])
    engine = int(app.stdout.readline().split()[1])
    cleanup += [app.pid, engine, worker]
    assert inner == ["bound", "True"], "a Job inside a Job"
    kill_pid(engine)
    assert wait_for(lambda: not pid_alive(worker), 15)
    assert app.poll() is None, "the app is not in the engine's Job"


def test_killing_the_own_tree_takes_the_workers(cleanup):
    p = spawn("""
        import subprocess, sys, time
        from sozvon_engine import platform_support as ps
        ps.bind_workers_to_process()
        w = subprocess.Popen([sys.executable, "-c", sys.argv[1]])
        print(w.pid, ps.owns_process_group(), flush=True)
        ps.kill_own_process_group()
        time.sleep(60)
    """, WORKER)
    worker, owns = p.stdout.readline().split()
    cleanup += [p.pid, int(worker)]
    assert owns == "True"
    p.wait(timeout=30)
    assert p.returncode != 0
    assert wait_for(lambda: not pid_alive(int(worker)), 15)


def test_no_job_means_the_engine_does_not_claim_its_workers():
    p = spawn("""
        from sozvon_engine import platform_support as ps
        print(ps.owns_process_group(), flush=True)
    """)
    assert p.communicate(timeout=30)[0].strip() == "False"


def test_a_normal_exit_with_a_job_stays_a_normal_exit():
    p = spawn("""
        from sozvon_engine import platform_support as ps
        ps.bind_workers_to_process()
    """)
    p.communicate(timeout=30)
    assert p.returncode == 0


# ---- stop signal ----

# CTRL_BREAK needs a shared console, so a driver on its own hidden console starts the engine and sends it.
BREAK_DRIVER = """
    import signal, subprocess, sys, time
    e = subprocess.Popen([sys.executable, "-c", sys.argv[1], sys.argv[2]],
                         creationflags=subprocess.CREATE_NEW_PROCESS_GROUP, stdin=subprocess.DEVNULL)
    import pathlib
    ready = pathlib.Path(sys.argv[2] + ".ready")
    for _ in range(600):
        if ready.exists():
            break
        time.sleep(0.05)
    e.send_signal(signal.CTRL_BREAK_EVENT)
    sys.exit(e.wait(timeout=30))
"""

BREAK_ENGINE = """
    import pathlib, sys, time
    from sozvon_engine.pipeline import guard
    guard.exit_on_sigterm()
    done = pathlib.Path(sys.argv[1])
    try:
        pathlib.Path(sys.argv[1] + ".ready").touch()
        for _ in range(600):
            time.sleep(0.05)
    finally:
        done.write_text("cleaned", encoding="utf-8")
"""


def test_ctrl_break_ends_the_run_through_finally_with_143(tmp_path):
    done = tmp_path / "done"
    info = subprocess.STARTUPINFO()
    info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    info.wShowWindow = 0
    p = spawn(BREAK_DRIVER, textwrap.dedent(BREAK_ENGINE), done, stdout=None,
              creationflags=subprocess.CREATE_NEW_CONSOLE, startupinfo=info)
    assert p.wait(timeout=60) == 143
    assert done.read_text(encoding="utf-8") == "cleaned"


# ---- known folders ----

def test_default_folders_come_from_known_folders(monkeypatch, win32, tmp_path):
    monkeypatch.setattr(win32, "_known_folder", lambda folder_id: tmp_path / folder_id)
    assert ps.default_data_dir() == tmp_path / win32._FOLDERID_LOCAL_APP_DATA / "Sozvon"
    assert ps.default_calls_dir() == tmp_path / win32._FOLDERID_PROFILE / "Sozvon Calls"


def test_default_folders_fall_back_when_the_call_fails(monkeypatch, win32, tmp_path):
    monkeypatch.setattr(win32, "_known_folder", lambda folder_id: None)
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))
    monkeypatch.setenv("USERPROFILE", str(tmp_path / "profile"))
    assert ps.default_data_dir() == tmp_path / "Sozvon"
    assert ps.default_calls_dir() == tmp_path / "profile" / "Sozvon Calls"


def test_calls_folder_setting_wins_over_the_default(monkeypatch, tmp_path):
    from sozvon_engine import paths
    monkeypatch.setenv("SOZVON_CALLS_DIR", str(tmp_path / "мои звонки"))
    assert paths.calls_dir() == tmp_path / "мои звонки"


def test_no_warning_for_a_calls_folder_outside_the_cloud(monkeypatch, win32, tmp_path, capsys):
    monkeypatch.setattr(win32, "_known_folder", lambda folder_id: tmp_path / "User")
    monkeypatch.setenv("OneDrive", str(tmp_path / "User" / "OneDrive"))
    monkeypatch.delenv("OneDriveConsumer", raising=False)
    monkeypatch.delenv("OneDriveCommercial", raising=False)
    win32.default_calls_dir()
    assert capsys.readouterr().err == ""


def test_warning_when_the_default_calls_folder_is_inside_onedrive(monkeypatch, win32, tmp_path, capsys):
    monkeypatch.setattr(win32, "_known_folder", lambda folder_id: tmp_path / "OneDrive" / "Profile")
    monkeypatch.setenv("OneDrive", str(tmp_path / "OneDrive"))
    win32.default_calls_dir()
    assert "OneDrive" in capsys.readouterr().err


def test_known_folders_are_real_folders(win32):
    for folder_id in (win32._FOLDERID_LOCAL_APP_DATA, win32._FOLDERID_PROFILE):
        assert win32._known_folder(folder_id).is_dir()


# ---- who can read the data folder ----

def _aces(path: Path) -> list:
    """(flags, trustee) of every entry of a folder's DACL, from its SDDL."""
    r = subprocess.run(["powershell.exe", "-NoProfile", "-Command", f"(Get-Acl -LiteralPath '{path}').Sddl"],
                       capture_output=True, text=True, errors="replace", timeout=60)
    assert r.returncode == 0, r.stderr
    dacl = r.stdout.strip().split("D:", 1)[1]
    return [(a.split(";")[1], a.split(";")[5]) for a in re.findall(r"\(([^()]*)\)", dacl)]


def test_data_folder_is_private_to_the_user(win32):
    """Voice prints and transcripts live here, and chmod does nothing on Windows: the profile's ACL is the protection.
    Everyone (WD), Users (BU) and Authenticated Users (AU) get nothing, and the engine adds no entry of its own."""
    assert ps.default_data_dir().is_relative_to(win32._known_folder(win32._FOLDERID_PROFILE))
    folder = win32._known_folder(win32._FOLDERID_LOCAL_APP_DATA) / f"Sozvon-acl-test-{os.getpid()}"
    folder.mkdir()
    try:
        (folder / "voices").mkdir()
        os.chmod(folder / "voices", 0o700)  # as voices.py does
        for path in (folder, folder / "voices"):
            aces = _aces(path)
            assert aces, "a DACL is present"
            assert all("ID" in flags for flags, _ in aces), f"only inherited entries: {aces}"
            assert not [t for _, t in aces if t in ("WD", "BU", "AU", "S-1-1-0", "S-1-5-32-545", "S-1-5-11")], aces
    finally:
        (folder / "voices").rmdir()
        folder.rmdir()


# ---- Recycle Bin (the shell call is replaced) ----

def _fake_shell(monkeypatch, win32, *, rc=0, aborted=False, delete=True):
    seen = {}

    def fake(ref):
        op = ref._obj
        seen.update(func=op.wFunc, flags=op.fFlags, to=op.pTo, hwnd=op.hwnd)
        path = ctypes.wstring_at(op.pFrom)
        seen["path"] = path
        seen["tail"] = ctypes.wstring_at(op.pFrom, len(path) + 2)
        op.fAnyOperationsAborted = aborted
        if delete and not rc and not aborted:
            import shutil
            shutil.rmtree(path)
        return rc

    monkeypatch.setattr(win32._shell32, "SHFileOperationW", fake)
    return seen


def test_trash_asks_the_shell_for_a_silent_undoable_delete(monkeypatch, win32, tmp_path):
    seen = _fake_shell(monkeypatch, win32)
    d = tmp_path / "call · Анна"
    d.mkdir()
    relative = Path(os.path.relpath(d))
    ps.move_to_trash(relative)
    assert not d.exists()
    assert seen["func"] == 3  # FO_DELETE
    assert seen["flags"] == 0x40 | 0x10 | 0x4 | 0x400  # ALLOWUNDO, NOCONFIRMATION, SILENT, NOERRORUI
    assert Path(seen["path"]).is_absolute() and Path(seen["path"]) == d.resolve()
    assert seen["tail"].endswith("\0\0"), "the list of paths ends with two zeros"


@pytest.mark.parametrize("kw", [{"rc": 2}, {"aborted": True}, {"delete": False}])
def test_trash_failure_is_an_oserror(monkeypatch, win32, tmp_path, kw):
    _fake_shell(monkeypatch, win32, **kw)
    d = tmp_path / "call"
    d.mkdir()
    with pytest.raises(OSError):
        ps.move_to_trash(d)
    assert d.exists()

