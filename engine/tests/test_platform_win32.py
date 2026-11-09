"""The Windows side of the platform seam: locks, the parent watchdog, the worker Job Object, stop signal, Recycle Bin.

Real processes wherever the behaviour is about processes. The Recycle Bin call is replaced, so tests leave nothing there.
"""
import ctypes
import os
import re
import subprocess
import sys
import textwrap
import threading
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


def run_and_ctrl_break(code: str, path) -> int:
    """Run code with `path` as its argument, send CTRL_BREAK once it created <path>.ready; -> its exit code."""
    info = subprocess.STARTUPINFO()
    info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    info.wShowWindow = 0
    p = spawn(BREAK_DRIVER, textwrap.dedent(code), path, stdout=None,
              creationflags=subprocess.CREATE_NEW_CONSOLE, startupinfo=info)
    return p.wait(timeout=120)


def test_ctrl_break_ends_the_run_through_finally_with_143(tmp_path):
    done = tmp_path / "done"
    assert run_and_ctrl_break(BREAK_ENGINE, done) == 143
    assert done.read_text(encoding="utf-8") == "cleaned"


def test_ctrl_break_removes_working_files(tmp_path):
    """test_run.test_sigterm_removes_working_files, with the Windows stop signal."""
    d = tmp_path / "2026-11-04 15-01"
    d.mkdir()
    assert run_and_ctrl_break("""
        import pathlib, sys, time
        from sozvon_engine.pipeline import guard, tracks
        d = pathlib.Path(sys.argv[1])
        guard.exit_on_sigterm()
        try:
            (d / ".work").mkdir()
            (d / ".work" / "mic.wav").write_bytes(b"x" * 1000)
            pathlib.Path(sys.argv[1] + ".ready").touch()
            for _ in range(600):
                time.sleep(0.05)
        finally:
            tracks.cleanup(d)
    """, d) == 143
    assert not (d / ".work").exists()


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


# ---- files someone else is holding ----

def _held(path, seconds):
    f = open(path, "rb")  # Python opens files without FILE_SHARE_DELETE, so a replace is refused meanwhile
    timer = threading.Timer(seconds, f.close)
    timer.start()
    return timer


def test_replace_waits_for_a_file_someone_holds(tmp_path):
    src, dst = tmp_path / "a", tmp_path / "b"
    src.write_text("новое", encoding="utf-8")
    dst.write_text("старое", encoding="utf-8")
    timer = _held(dst, 0.5)
    ps.replace_file(src, dst)
    timer.join()
    assert dst.read_text(encoding="utf-8") == "новое"


def test_replace_gives_up_on_a_file_held_for_long(monkeypatch, tmp_path, win32):
    monkeypatch.setattr(win32, "_BUSY_WAIT", 0.3)
    src, dst = tmp_path / "a", tmp_path / "b"
    src.write_text("x")
    dst.write_text("y")
    with open(dst, "rb"):
        with pytest.raises(PermissionError):
            ps.replace_file(src, dst)


def test_other_errors_are_not_waited_for(monkeypatch, tmp_path, win32):
    monkeypatch.setattr(win32, "_BUSY_WAIT", 30)
    start = time.time()
    with pytest.raises(FileNotFoundError):
        ps.replace_file(tmp_path / "missing", tmp_path / "b")
    assert time.time() - start < 2


# ---- names of call folders ----

CID = "2026-11-04 15-01"


def folder(name, monkeypatch, tmp_path):
    from sozvon_engine import remote
    monkeypatch.setenv("SOZVON_CALLS_DIR", str(tmp_path))
    return remote.safe_folder(name, CID)


@pytest.mark.parametrize("name,want", [
    (f'{CID} · a<b>c"d|e?f*g', f"{CID} · a-b-c-d-e-f-g"),
    (f"{CID} · тема.", f"{CID} · тема"),
    (f"{CID} · тема. . ", f"{CID} · тема"),
    (f"{CID} · Анна", f"{CID} · Анна"),
    (CID, CID),
])
def test_call_folder_names_valid_on_windows(monkeypatch, tmp_path, name, want):
    assert folder(name, monkeypatch, tmp_path) == want


@pytest.mark.parametrize("name", ["con", "CON", "Nul.txt", "aux", "prn.x", "COM1", "lpt9.log", "COM¹", "lpt³", "conin$", "CONOUT$"])
def test_reserved_names_become_the_id(tmp_path, win32, name):
    assert win32.call_folder_name(name, CID, tmp_path) == CID


def test_names_that_only_begin_like_reserved_ones_stay(tmp_path, win32):
    assert win32.call_folder_name(f"{CID} · CON", CID, tmp_path) == f"{CID} · CON"
    assert win32.call_folder_name("CONSOLE", "CONSOLE", tmp_path) == "CONSOLE"


def test_a_long_name_leaves_room_for_the_files_inside(monkeypatch, tmp_path, win32):
    calls = tmp_path / ("д" * 60)
    name = f"{CID} · " + "тема " * 80
    got = win32.call_folder_name(name, CID, calls)
    assert got.startswith(CID + " ") and not got.endswith((" ", "."))
    assert len(str(calls)) + 1 + len(got) + 1 + win32._LONGEST_INSIDE <= 259


def test_no_room_at_all_gives_the_id(tmp_path, win32):
    assert win32.call_folder_name(f"{CID} · тема", CID, tmp_path / ("д" * 300)) == CID


# ---- external programs: absolute paths only ----

def test_tool_path_is_next_to_python_and_must_exist(monkeypatch, tmp_path):
    monkeypatch.setattr(sys, "executable", str(tmp_path / "python.exe"))
    with pytest.raises(FileNotFoundError):
        ps.tool_path("ffmpeg")
    (tmp_path / "ffmpeg.exe").write_bytes(b"x")
    assert ps.tool_path("ffmpeg") == str(tmp_path / "ffmpeg.exe")


def test_tool_path_of_a_system_tool_is_in_the_system_folder():
    curl = Path(ps.tool_path("curl"))
    assert curl.is_absolute() and curl.name.lower() == "curl.exe" and curl.parent.name.lower() == "system32"


def test_a_forged_ffmpeg_in_the_current_folder_is_not_run(monkeypatch, tmp_path):
    """A call folder or a phone folder can hold anything, and CreateProcess looks in the current folder before PATH."""
    from sozvon_engine import audio
    if not (Path(sys.executable).parent / "ffmpeg.exe").exists():
        pytest.skip("this environment has no ffmpeg.exe next to python")
    import shutil
    import wave
    with wave.open(str(tmp_path / "a.wav"), "wb") as w:
        w.setnchannels(1), w.setsampwidth(2), w.setframerate(16000), w.writeframes(b"\x10\x00" * 16000)
    shutil.copy(BASE_PYTHON, tmp_path / "ffmpeg.exe")  # cannot start here, and is no ffmpeg if it could
    monkeypatch.chdir(tmp_path)
    assert len(audio.decode(tmp_path / "a.wav")) == 16000


def test_a_forged_assistant_in_the_current_folder_is_not_found(monkeypatch, tmp_path):
    (tmp_path / "claude.exe").write_bytes(b"x")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("PATH", str(tmp_path / "elsewhere"))
    assert ps.find_cli("claude", []) is None


def test_exe_wins_over_cmd_and_scripts_are_ignored(monkeypatch, tmp_path):
    (tmp_path / "tool.ps1").write_text("x")
    (tmp_path / "tool.bat").write_text("x")
    monkeypatch.setenv("PATH", str(tmp_path))
    assert ps.find_cli("tool", []) is None
    (tmp_path / "tool.exe").write_bytes(b"x")
    assert ps.find_cli("tool", []) == str(tmp_path / "tool.exe")
    assert ps.cli_argv(str(tmp_path / "tool.exe")) == [str(tmp_path / "tool.exe")]


NPM_SHIM = r"""@ECHO off
GOTO start
:find_dp0
SET dp0=%~dp0
EXIT /b
:start
SETLOCAL
CALL :find_dp0

IF EXIST "%dp0%\node.exe" (
  SET "_prog=%dp0%\node.exe"
) ELSE (
  SET "_prog=node"
  SET PATHEXT=%PATHEXT:;.JS;=;%
)

endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\{target}" %*
"""

SPY_JS = """
const fs = require('fs');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => input += c);
process.stdin.on('end', () => {
  fs.writeFileSync(process.env.SPY_OUT, JSON.stringify({argv: process.argv.slice(2), stdin: input, cwd: process.cwd()}), 'utf8');
  process.stdout.write('ответ готов');
});
"""


@pytest.fixture
def npm_dir(tmp_path):
    d = tmp_path / "Программы и тесты"
    d.mkdir()
    return d


def _shim(folder: Path, name: str, target: str = r"node_modules\pkg\cli.js", script: str | None = SPY_JS) -> Path:
    (folder / f"{name}.cmd").write_text(NPM_SHIM.format(target=target), encoding="utf-8")
    if script is not None:
        f = folder / target
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(script, encoding="utf-8")
    return folder / f"{name}.cmd"


def _need_node():
    if ps.find_cli("node", []) is None:
        pytest.skip("no node on PATH")


def test_npm_shim_runs_node_with_the_script_directly(npm_dir):
    _need_node()
    argv = ps.cli_argv(str(_shim(npm_dir, "codex")))
    assert len(argv) == 2 and Path(argv[0]).is_absolute() and Path(argv[0]).name.lower() == "node.exe"
    assert argv[1] == str((npm_dir / "node_modules" / "pkg" / "cli.js").resolve())


def test_node_next_to_the_shim_is_preferred(npm_dir):
    (npm_dir / "node.exe").write_bytes(b"x")
    assert ps.cli_argv(str(_shim(npm_dir, "codex")))[0] == str(npm_dir.resolve() / "node.exe")


@pytest.mark.parametrize("target,script", [
    (r"..\outside.js", SPY_JS),                         # leaves the folder of the shim
    (r"node_modules\..\..\outside.js", SPY_JS),
    (r"node_modules\pkg\missing.js", None),             # no such file
])
def test_npm_shim_pointing_elsewhere_is_refused(npm_dir, target, script):
    shim = _shim(npm_dir, "codex", target, script)
    with pytest.raises(FileNotFoundError):
        ps.cli_argv(str(shim))
    assert ps.find_cli("codex", [npm_dir]) is None


def test_a_cmd_file_that_is_no_npm_shim_is_refused(monkeypatch, npm_dir):
    monkeypatch.setenv("PATH", "")  # a real claude on this machine must not answer for the fake one
    (npm_dir / "claude.cmd").write_text("@echo off\r\nsomething.exe %*\r\n", encoding="utf-8")
    with pytest.raises(FileNotFoundError):
        ps.cli_argv(str(npm_dir / "claude.cmd"))
    assert ps.find_cli("claude", [npm_dir]) is None


NASTY = 'Анна: & echo pwned > pwned.txt | %PATH% "кавычки" <x> ^ `id` $(id) ✓\nвторая строка'


def _assistant(monkeypatch, npm_dir, tmp_path, name="claude"):
    from sozvon_engine import llm
    _need_node()
    monkeypatch.setenv("PATH", str(Path(ps.find_cli("node", [])).parent))  # only node, no real assistant of this machine
    _shim(npm_dir, name)
    monkeypatch.setattr(llm, "BIN_DIRS", [npm_dir])
    monkeypatch.setenv("SOZVON_LLM", name)
    monkeypatch.setenv("SPY_OUT", str(tmp_path / "spy.json"))
    return llm


def test_transcript_reaches_the_assistant_untouched_through_stdin(monkeypatch, npm_dir, tmp_path):
    """No cmd.exe anywhere: the text of a call can hold any characters. --tools "" must arrive as an empty argument."""
    import json
    llm = _assistant(monkeypatch, npm_dir, tmp_path)
    cwd = tmp_path / "звонок с пробелом"
    cwd.mkdir()
    out, name, err = llm.run(NASTY, cwd)
    assert (out, name, err) == ("ответ готов", "claude", "")
    spy = json.loads((tmp_path / "spy.json").read_text(encoding="utf-8"))
    assert spy["stdin"].replace("\r\n", "\n") == NASTY  # text mode writes line ends as CRLF here, every character is intact
    assert spy["argv"][spy["argv"].index("--tools") + 1] == "", "an empty argument, not a missing one"
    assert not list(cwd.iterdir()), "nothing ran"


def test_project_discovery_is_off_on_windows(monkeypatch, npm_dir, tmp_path):
    llm = _assistant(monkeypatch, npm_dir, tmp_path)
    out, name, err = llm.run("x", tmp_path, agentic=True)
    assert out is None and name == "claude" and err
    assert not (tmp_path / "spy.json").exists(), "the assistant was not started"


@pytest.mark.parametrize("name", ["codex", "cursor"])
def test_chosen_codex_and_cursor_fail_with_a_clear_error(monkeypatch, npm_dir, tmp_path, name):
    binary = {"codex": "codex", "cursor": "cursor-agent"}[name]
    llm = _assistant(monkeypatch, npm_dir, tmp_path, binary)
    monkeypatch.setenv("SOZVON_LLM", name)
    assert llm.backend()[0] == name, "it counts as chosen, so the failure reaches warnings"
    out, got, err = llm.run("x", tmp_path)
    assert out is None and got == name and err
    assert not (tmp_path / "spy.json").exists(), "the assistant was not started"


def test_a_failed_codex_summary_is_a_warning(monkeypatch, npm_dir, tmp_path):
    from sozvon_engine.pipeline import summary
    llm = _assistant(monkeypatch, npm_dir, tmp_path, "codex")
    monkeypatch.setenv("SOZVON_LLM", "codex")
    warned = []
    assert summary.summarize("текст", "Я", tmp_path, warn=warned.append) is None
    assert len(warned) == 1 and warned[0].startswith("codex")
    assert llm is not None


def test_auto_does_not_choose_codex_or_cursor(monkeypatch, npm_dir, tmp_path):
    llm = _assistant(monkeypatch, npm_dir, tmp_path, "codex")
    _shim(npm_dir, "cursor-agent")
    monkeypatch.setenv("SOZVON_LLM", "auto")
    monkeypatch.setenv("PATH", str(npm_dir))
    assert llm.backend() == (None, None)


# ---- the process itself ----

PREPARE = """
    import ctypes, sys
    from sozvon_engine import runtime
    runtime.prepare()
    print("Анна · ✓", flush=True)
    k = ctypes.WinDLL("kernel32")
    k.GetCurrentProcess.restype = ctypes.c_void_p
    k.GetPriorityClass.argtypes = [ctypes.c_void_p]
    print(hex(k.GetPriorityClass(k.GetCurrentProcess())), flush=True)
    import os
    print(os.environ["SOZVON_THREADS"], os.environ["OMP_NUM_THREADS"], flush=True)
"""


def _prepared(tmp_path, **extra) -> list:
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONUTF8", "PYTHONIOENCODING", "SOZVON_THREADS")}
    env.update(PYTHONPATH=str(ENGINE_ROOT), SOZVON_DATA_DIR=str(tmp_path), **extra)
    r = subprocess.run([sys.executable, "-c", textwrap.dedent(PREPARE)], capture_output=True, env=env, timeout=60)
    assert r.returncode == 0, r.stderr.decode("utf-8", "replace")
    return r.stdout.decode("utf-8").split()


def test_output_is_utf8_in_a_pipe(tmp_path):
    assert _prepared(tmp_path)[:3] == ["Анна", "·", "✓"]


def test_low_priority_always(tmp_path):
    assert _prepared(tmp_path)[3] == "0x4000"  # BELOW_NORMAL_PRIORITY_CLASS


def test_one_thread_limit_for_every_library(tmp_path):
    half = str(max(1, os.cpu_count() // 2))
    assert _prepared(tmp_path)[4:6] == [half, half]
    assert _prepared(tmp_path, SOZVON_THREADS="2")[4:6] == ["2", "2"], "the setting wins"


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

