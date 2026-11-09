"""The Windows half of platform_support: file locks, the parent watchdog, the worker Job Object, the Recycle Bin.

Imported only on win32 (ctypes.WinDLL does not exist elsewhere), only from inside the win32 branches of
platform_support. Standard library and Win32 only.
"""
import ctypes
import hashlib
import os
import re
import sys
import time
import uuid
from ctypes import wintypes
from pathlib import Path

_kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
_shell32 = ctypes.WinDLL("shell32", use_last_error=True)
_ole32 = ctypes.WinDLL("ole32", use_last_error=True)

_ULONG_PTR = ctypes.c_size_t


class _OVERLAPPED(ctypes.Structure):
    _fields_ = [("Internal", _ULONG_PTR), ("InternalHigh", _ULONG_PTR), ("Offset", wintypes.DWORD),
                ("OffsetHigh", wintypes.DWORD), ("hEvent", wintypes.HANDLE)]


class _PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", _ULONG_PTR), ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", wintypes.LONG), ("dwFlags", wintypes.DWORD),
                ("szExeFile", wintypes.WCHAR * 260)]


class _JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", _ULONG_PTR), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]


class _IO_COUNTERS(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in ("ReadOps", "WriteOps", "OtherOps", "ReadBytes", "WriteBytes", "OtherBytes")]


class _JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [("BasicLimitInformation", _JOBOBJECT_BASIC_LIMIT_INFORMATION), ("IoInfo", _IO_COUNTERS),
                ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]


class _SHFILEOPSTRUCTW(ctypes.Structure):
    _fields_ = [("hwnd", wintypes.HWND), ("wFunc", wintypes.UINT), ("pFrom", ctypes.c_void_p), ("pTo", ctypes.c_void_p),
                ("fFlags", ctypes.c_ushort), ("fAnyOperationsAborted", wintypes.BOOL),
                ("hNameMappings", ctypes.c_void_p), ("lpszProgressTitle", wintypes.LPCWSTR)]


def _sig(fn, restype, *argtypes):
    fn.restype = restype
    fn.argtypes = argtypes


_LPOV = ctypes.POINTER(_OVERLAPPED)
_sig(_kernel32.LockFileEx, wintypes.BOOL, wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, _LPOV)
_sig(_kernel32.UnlockFileEx, wintypes.BOOL, wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, _LPOV)
_sig(_kernel32.OpenProcess, wintypes.HANDLE, wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
_sig(_kernel32.CloseHandle, wintypes.BOOL, wintypes.HANDLE)
_sig(_kernel32.WaitForSingleObject, wintypes.DWORD, wintypes.HANDLE, wintypes.DWORD)
_sig(_kernel32.GetCurrentProcess, wintypes.HANDLE)
_sig(_kernel32.GetProcessTimes, wintypes.BOOL, wintypes.HANDLE, *[ctypes.POINTER(ctypes.c_uint64)] * 4)
_sig(_kernel32.QueryFullProcessImageNameW, wintypes.BOOL, wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
     ctypes.POINTER(wintypes.DWORD))
_sig(_kernel32.CreateToolhelp32Snapshot, wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD)
_sig(_kernel32.Process32FirstW, wintypes.BOOL, wintypes.HANDLE, ctypes.POINTER(_PROCESSENTRY32W))
_sig(_kernel32.Process32NextW, wintypes.BOOL, wintypes.HANDLE, ctypes.POINTER(_PROCESSENTRY32W))
_sig(_kernel32.CreateJobObjectW, wintypes.HANDLE, wintypes.LPVOID, wintypes.LPCWSTR)
_sig(_kernel32.SetInformationJobObject, wintypes.BOOL, wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD)
_sig(_kernel32.AssignProcessToJobObject, wintypes.BOOL, wintypes.HANDLE, wintypes.HANDLE)
_sig(_kernel32.TerminateJobObject, wintypes.BOOL, wintypes.HANDLE, wintypes.UINT)

_sig(_shell32.SHGetKnownFolderPath, ctypes.c_long, ctypes.c_void_p, wintypes.DWORD, wintypes.HANDLE, ctypes.POINTER(ctypes.c_void_p))
_sig(_ole32.CoTaskMemFree, None, ctypes.c_void_p)
_sig(_kernel32.GetSystemDirectoryW, wintypes.UINT, wintypes.LPWSTR, wintypes.UINT)
_sig(_kernel32.SetPriorityClass, wintypes.BOOL, wintypes.HANDLE, wintypes.DWORD)
_sig(_kernel32.SetProcessInformation, wintypes.BOOL, wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD)

_INVALID_HANDLE = wintypes.HANDLE(-1).value


# --- known folders ---

_FOLDERID_LOCAL_APP_DATA = "F1B32785-6FBA-4FCF-9D55-7B8E7F157091"
_FOLDERID_PROFILE = "5E6C858F-0E22-4760-9AFE-EA3317B67173"


def _known_folder(folder_id: str) -> Path | None:
    """The real location of a Known Folder, wherever the user or a policy moved it. None if the call failed."""
    guid = ctypes.create_string_buffer(uuid.UUID(folder_id).bytes_le)
    out = ctypes.c_void_p()
    code = _shell32.SHGetKnownFolderPath(guid, 0, None, ctypes.byref(out))
    try:
        return Path(ctypes.wstring_at(out.value)) if code == 0 and out.value else None
    finally:
        if out.value:
            _ole32.CoTaskMemFree(out)


def default_data_dir() -> Path:
    """Local, not Roaming: gigabytes of models and the .venv."""
    base = _known_folder(_FOLDERID_LOCAL_APP_DATA) or os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local"
    return Path(base) / "Sozvon"


def _cloud_folders() -> list:
    return [v for v in map(os.environ.get, ("OneDrive", "OneDriveConsumer", "OneDriveCommercial")) if v]


def _is_inside(path: Path, folder: str) -> bool:
    a, b = os.path.normcase(os.path.normpath(path)), os.path.normcase(os.path.normpath(folder))
    return a == b or a.startswith(b.rstrip(os.sep) + os.sep)


def default_calls_dir() -> Path:
    """The profile folder, not Documents: Known Folder Move can put Documents in OneDrive, and recordings must not
    be uploaded to a cloud without the user choosing that. The profile itself is not redirected by it."""
    calls = Path(_known_folder(_FOLDERID_PROFILE) or os.environ.get("USERPROFILE") or Path.home()) / "Sozvon Calls"
    if any(_is_inside(calls, cloud) for cloud in _cloud_folders()):
        print(f"WARNING: the default calls folder {calls} is inside OneDrive, recordings may be uploaded to the cloud. "
              "Set SOZVON_CALLS_DIR to a local folder.", file=sys.stderr, flush=True)
    return calls


# --- file locks ---

_LOCKFILE_FAIL_IMMEDIATELY = 0x1
_LOCKFILE_EXCLUSIVE_LOCK = 0x2
_ERROR_NOT_LOCKED = 158
_ERROR_LOCK_VIOLATION = 33
_ERROR_IO_PENDING = 997
_LOCK_POLL = 0.05  # seconds. Polled, not a blocking call: a stop signal cannot run while a thread is inside one.


def _os_handle(fd: int):
    import msvcrt
    return msvcrt.get_osfhandle(fd)


def lock_exclusive(fd: int, wait: bool = True) -> bool:
    """Byte 0 of an open file, exclusively, like flock: wait=True returns only once it holds the lock.

    A future Windows app takes the same byte of the same <file>.lock with LockFileEx. The OS releases it when the
    descriptor closes or the process dies, however it dies.
    """
    handle = _os_handle(fd)
    flags = _LOCKFILE_EXCLUSIVE_LOCK | _LOCKFILE_FAIL_IMMEDIATELY
    while True:
        if _kernel32.LockFileEx(handle, flags, 0, 1, 0, ctypes.byref(_OVERLAPPED())):
            return True
        err = ctypes.get_last_error()
        if err not in (_ERROR_LOCK_VIOLATION, _ERROR_IO_PENDING):
            raise ctypes.WinError(err)
        if not wait:
            return False
        time.sleep(_LOCK_POLL)


def unlock(fd: int) -> None:
    """Release the lock. No lock held is not an error, as with flock."""
    if not _kernel32.UnlockFileEx(_os_handle(fd), 0, 1, 0, ctypes.byref(_OVERLAPPED())):
        err = ctypes.get_last_error()
        if err != _ERROR_NOT_LOCKED:
            raise ctypes.WinError(err)


_CALL_ID = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}(?:-\d+)?(?= |$)")  # calls.ID_RE: the id survives renames


def open_call_lock(folder: Path, locks_dir: Path) -> int:
    """Descriptor to lock for "one run on this call". A directory cannot be opened as a file here, and a lock file
    inside the call would stop it from being renamed after transcription, so the file lives in locks_dir, named after
    the call id, which a rename keeps."""
    name = Path(folder).name
    match = _CALL_ID.match(name)
    locks_dir.mkdir(parents=True, exist_ok=True)
    key = match.group(0) if match else hashlib.sha256(name.encode("utf-8")).hexdigest()  # an id is a safe file name
    return os.open(locks_dir / f"{key}.lock", os.O_RDWR | os.O_CREAT, 0o600)


# --- the parent watchdog ---

_SYNCHRONIZE = 0x00100000
_PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
_WAIT_OBJECT_0 = 0
_TH32CS_SNAPPROCESS = 0x2
_ERROR_ACCESS_DENIED = 5
_UNOBSERVABLE = object()  # alive, but this process may not open it

_watch_ready = False
_watches: list = []  # handles to the processes whose death ends the engine
_gone_at_start = False


def _created(handle) -> int:
    """Creation time of a process, 0 if unknown."""
    times = [ctypes.c_uint64() for _ in range(4)]
    if not _kernel32.GetProcessTimes(handle, *[ctypes.byref(t) for t in times]):
        return 0
    return times[0].value


def _open_living(pid: int, born_before: int):
    """A handle to a process that is alive and older than born_before, None if it died or its pid was reused,
    _UNOBSERVABLE if it exists but may not be opened."""
    handle = _kernel32.OpenProcess(_SYNCHRONIZE | _PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return _UNOBSERVABLE if ctypes.get_last_error() == _ERROR_ACCESS_DENIED else None
    if _kernel32.WaitForSingleObject(handle, 0) == _WAIT_OBJECT_0 or _created(handle) > born_before:
        _kernel32.CloseHandle(handle)
        return None
    return handle


def _image_path(handle) -> str:
    size = wintypes.DWORD(32768)
    buf = ctypes.create_unicode_buffer(size.value)
    if not _kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
        return ""
    return buf.value


def _same_file(a: str, b: str) -> bool:
    return bool(a and b) and os.path.normcase(os.path.normpath(a)) == os.path.normcase(os.path.normpath(b))


def _is_venv_launcher(handle) -> bool:
    """.venv\\Scripts\\python.exe only starts the real python and waits for it, so it lives as long as the engine does.
    Decided by the full image path: with a plain python no launcher exists and the parent is the app itself."""
    return sys.prefix != sys.base_prefix and _same_file(_image_path(handle), sys.executable)


def _parent_of(pid: int) -> int | None:
    snapshot = _kernel32.CreateToolhelp32Snapshot(_TH32CS_SNAPPROCESS, 0)
    if snapshot in (None, _INVALID_HANDLE):
        return None
    try:
        entry = _PROCESSENTRY32W()
        entry.dwSize = ctypes.sizeof(entry)
        ok = _kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while ok:
            if entry.th32ProcessID == pid:
                return entry.th32ParentProcessID
            ok = _kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        _kernel32.CloseHandle(snapshot)
    return None


def _open_watches():
    """The processes to watch, opened once. None: the parent is gone already.

    With a launcher both it and its parent count: the app that stops the engine by killing its child kills the launcher,
    and an engine left running would hold the call lock and later overwrite what the app wrote."""
    pid = os.getppid()
    parent = _open_living(pid, _created(_kernel32.GetCurrentProcess()))
    if parent is None:
        return None
    if parent is _UNOBSERVABLE:
        return []
    if not _is_venv_launcher(parent):
        return [parent]
    above_pid = _parent_of(pid)
    above = _open_living(above_pid, _created(parent)) if above_pid else None
    if above is None:
        _kernel32.CloseHandle(parent)
        return None
    return [parent] if above is _UNOBSERVABLE else [parent, above]


def parent_pid() -> int:
    """os.getppid() while the parent lives and 1 once it died, as on macOS: getppid alone never changes on Windows.

    A parent gone before the first call reads as 1 from that call on, which on macOS means an orphan at launch: the
    engine's watchdog then has nothing to watch, and the run goes on."""
    global _watches, _watch_ready, _gone_at_start
    if not _watch_ready:
        opened = _open_watches()
        _gone_at_start = opened is None
        _watches = opened or []
        _watch_ready = True
    if _gone_at_start or any(_kernel32.WaitForSingleObject(h, 0) == _WAIT_OBJECT_0 for h in _watches):
        return 1
    return os.getppid()


# --- workers die with the engine ---

_JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9
_JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000

_job = None


def bind_workers_to_process() -> bool:
    """Put this process and every child it starts from now on (ffmpeg, an assistant CLI) in a Job that the OS kills
    when the last handle closes, so with this process, however it dies. Processes started by others stay outside.
    Inside a Job of the app this nests (Windows 8 and later). False: not bound, the engine works on without it."""
    global _job
    if _job is not None:
        return True
    job = _kernel32.CreateJobObjectW(None, None)
    if not job:
        return False
    info = _JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
    info.BasicLimitInformation.LimitFlags = _JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if (_kernel32.SetInformationJobObject(job, _JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, ctypes.byref(info), ctypes.sizeof(info))
            and _kernel32.AssignProcessToJobObject(job, _kernel32.GetCurrentProcess())):
        _job = job
        return True
    _kernel32.CloseHandle(job)
    return False


def owns_process_group() -> bool:
    return _job is not None


def kill_own_process_group() -> None:
    """Kill this process and its workers. Reached only with a bound Job."""
    if _job is not None:
        _kernel32.TerminateJobObject(_job, 1)
    os._exit(1)


# --- external programs: absolute paths only ---
#
# CreateProcess looks in the current folder before PATH, and a call folder or a phone folder can hold anything, so no
# program is ever started by its short name. A batch file would go through cmd.exe, where the characters of a call's
# text are commands, so none is ever started at all: npm's .cmd wrapper is read and node runs its script directly.

_SYSTEM_TOOLS = ("curl",)
_NPM_TARGET = re.compile(r'"%~?dp0%?\\([^"]+)"\s+%\*')
_BELOW_NORMAL_PRIORITY_CLASS = 0x4000
_PROCESS_MEMORY_PRIORITY = 0
_MEMORY_PRIORITY_BELOW_NORMAL = 4


def _system_dir() -> Path:
    buf = ctypes.create_unicode_buffer(32768)
    if not _kernel32.GetSystemDirectoryW(buf, len(buf)):
        raise ctypes.WinError(ctypes.get_last_error())
    return Path(buf.value)


def tool_path(name: str) -> str:
    """Absolute path of a program the engine runs: next to python in the .venv, or in System32. FileNotFoundError if absent."""
    folder = _system_dir() if name in _SYSTEM_TOOLS else Path(sys.executable).parent
    path = folder / f"{name}.exe"
    if not path.is_file():
        raise FileNotFoundError(name)
    return str(path)


def _search_dirs(extra) -> list:
    """Absolute folders only: an empty or relative entry in PATH means the current folder."""
    entries = [e.strip().strip('"') for e in os.environ.get("PATH", "").split(os.pathsep)] + [str(d) for d in extra]
    return [Path(e) for e in entries if e and os.path.isabs(e)]


def _npm_script(wrapper: Path) -> Path:
    """The script npm's .cmd wrapper starts, if it lies inside the wrapper's folder and exists."""
    targets = _NPM_TARGET.findall(wrapper.read_text(encoding="utf-8", errors="replace"))
    if len(targets) != 1:
        raise FileNotFoundError(f"{wrapper}: not an npm wrapper")
    base = wrapper.parent.resolve()
    script = (base / targets[0]).resolve()
    if not script.is_relative_to(base) or not script.is_file():
        raise FileNotFoundError(f"{wrapper}: no script inside its folder")
    return script


def _node_for(wrapper: Path) -> str:
    beside = wrapper.parent.resolve() / "node.exe"
    if beside.is_file():
        return str(beside)
    for folder in _search_dirs([]):
        if (folder / "node.exe").is_file():
            return str(folder / "node.exe")
    raise FileNotFoundError("node")


def cli_argv(path: str) -> list:
    """How to start a command line tool found by find_cli. FileNotFoundError if it cannot be started safely."""
    file = Path(path)
    suffix = file.suffix.lower()
    if suffix == ".exe":
        return [str(file)]
    if suffix == ".cmd":
        script = _npm_script(file)
        return [_node_for(file), str(script)]
    raise FileNotFoundError(f"{path}: only .exe and npm's .cmd wrappers are started")


def find_cli(name: str, extra_dirs) -> str | None:
    """Absolute path of a command line tool that can be started safely; None if there is none."""
    for folder in _search_dirs(extra_dirs):
        for suffix in (".exe", ".cmd"):
            candidate = folder / f"{name}{suffix}"
            if candidate.is_file():
                try:
                    cli_argv(str(candidate))
                except (OSError, ValueError):
                    continue
                return str(candidate)
    return None


class _MEMORY_PRIORITY_INFORMATION(ctypes.Structure):
    _fields_ = [("MemoryPriority", wintypes.ULONG)]


def prepare_process() -> None:
    """UTF-8 on stdout and stderr, which default to the console code page in a pipe; low priority always, inherited by
    ffmpeg and the other children (measured: no cost in speed, unlike the background mode or EcoQoS)."""
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    me = _kernel32.GetCurrentProcess()
    _kernel32.SetPriorityClass(me, _BELOW_NORMAL_PRIORITY_CLASS)
    memory = _MEMORY_PRIORITY_INFORMATION(_MEMORY_PRIORITY_BELOW_NORMAL)
    _kernel32.SetProcessInformation(me, _PROCESS_MEMORY_PRIORITY, ctypes.byref(memory), ctypes.sizeof(memory))


# --- the Recycle Bin ---

_FO_DELETE = 3
_FOF_SILENT = 0x4
_FOF_NOCONFIRMATION = 0x10
_FOF_ALLOWUNDO = 0x40
_FOF_NOERRORUI = 0x400


def move_to_trash(path: Path) -> None:
    """Move a folder to the Recycle Bin, without any window. Raises OSError when that did not happen."""
    target = str(Path(path).resolve())
    source = ctypes.create_unicode_buffer(target + "\0")  # the list of paths ends with two zeros
    op = _SHFILEOPSTRUCTW()
    op.wFunc = _FO_DELETE
    op.pFrom = ctypes.addressof(source)
    op.fFlags = _FOF_ALLOWUNDO | _FOF_NOCONFIRMATION | _FOF_SILENT | _FOF_NOERRORUI
    code = _shell32.SHFileOperationW(ctypes.byref(op))
    if code != 0:
        raise OSError(f"could not move {target} to the Recycle Bin: error {code:#x}")
    if op.fAnyOperationsAborted:
        raise OSError(f"moving {target} to the Recycle Bin was aborted")
    if Path(target).exists():
        raise OSError(f"{target} is still there after moving it to the Recycle Bin")
