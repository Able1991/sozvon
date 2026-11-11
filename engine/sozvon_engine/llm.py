"""Cloud assistant for summaries and project discovery: Claude Code, Codex CLI or Cursor CLI.

Choice: SOZVON_LLM = auto | claude | codex | cursor | none (default auto: the first
installed of claude, codex, cursor). Uses the user's subscription in the respective CLI.
Text goes to Anthropic (claude), OpenAI (codex) or Cursor and the model chosen there (cursor).
"""
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from . import config, paths, platform_support
from .i18n import t

BIN_DIRS = platform_support.tool_bin_dirs()


def _find(name: str):
    return platform_support.find_cli(name, BIN_DIRS)


# One line per assistant call in <data>/assistant.log (Settings → Diagnostics puts it in the zip): which CLI, the
# command, how it ended. The request never: it goes by stdin or request.md, and an argument equal to it is masked.
JOURNAL = "assistant.log"
JOURNAL_MAX = 1_000_000


def journal(cmd, prompt: str, code, seconds: float, err: str = "") -> None:
    try:
        args = ["<request>" if a == prompt else a for a in cmd]
        if platform_support.SYSTEM == "win32":
            # Programs by name, not by path: cli_argv puts an interpreter and a script path in front, and the paths
            # carry the user's profile folder into the diagnostics.
            args = [Path(a).stem if os.path.isabs(a) and Path(a).is_file() else a for a in args]
        line = (f"{time.strftime('%Y-%m-%d %H:%M:%S')} {shlex.join(args)} | exit {code} | {seconds:.1f} s"
                + (" | " + " ".join(err.split())[-400:] if err.strip() else ""))
        f = paths.data_dir() / JOURNAL
        if f.exists() and f.stat().st_size > JOURNAL_MAX:
            keep = f.read_text(encoding="utf-8", errors="replace")[-JOURNAL_MAX // 2:]
            f.write_text(keep[keep.find("\n") + 1:], encoding="utf-8")
        with f.open("a", encoding="utf-8") as out:
            out.write(line + "\n")
    except Exception:  # noqa: BLE001 - a journal never fails a summary
        pass


def _exec(cmd, prompt: str, **kw) -> subprocess.CompletedProcess:
    """subprocess.run with a journal line; a timeout is journalled and raised again."""
    start = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, **platform_support.TEXT_MODE, **kw)
    except subprocess.TimeoutExpired:
        journal(cmd, prompt, "timeout", time.time() - start)
        raise
    journal(cmd, prompt, r.returncode, time.time() - start, r.stderr if r.returncode else "")
    return r


# Backend name -> CLI binary, in auto-detection order.
BINARIES = {"claude": "claude", "codex": "codex", "cursor": "cursor-agent"}


def backend(settings: config.Settings | None = None, only: str | None = None):
    """-> ('claude'|'codex'|'cursor', path) or (None, None). only: that one assistant, whatever the settings say."""
    want = only or (settings or config.load()).llm
    if want == "none":
        return None, None
    allowed = platform_support.AUTO_ASSISTANTS
    order = [want] if want in BINARIES else [n for n in BINARIES if allowed is None or n in allowed]
    for name in order:
        path = _find(BINARIES[name])
        if path:
            return name, path
    return None, None


def vendor(name) -> str:
    return {"claude": "Anthropic", "codex": "OpenAI", "cursor": "Cursor"}.get(name, "")


def _warn_unverified(name: str) -> None:
    """Windows: what is not known about the assistant the user chose, in the log of the call."""
    if platform_support.SYSTEM != "win32" or name == "claude":
        return
    print(t("log_assistant_unverified", name=name), file=sys.stderr, flush=True)
    if name == "cursor":
        print(t("log_cursor_no_file_sandbox"), file=sys.stderr, flush=True)


def run(prompt: str, cwd: Path, agentic: bool = False, timeout: int = 600, on_event=None, only: str | None = None):
    """Run a request. agentic=True: allow reading files (and Claude sessions).

    on_event(name, input): called on every agent step (claude only), for progress.
    -> (answer text, backend name, error or "").
    """
    settings = config.load()
    name, path = backend(settings, only)
    if not name:
        if only in BINARIES:
            return None, None, f"не найден {BINARIES[only]} CLI"
        return None, None, "не найден ни claude, ни codex, ни cursor-agent CLI"
    if agentic and platform_support.AGENTIC_OFF:
        return None, name, t("llm_no_discovery")
    _warn_unverified(name)
    if name == "claude":
        # --setting-sources project: skip ~/.claude/settings.json, otherwise the user's allow rules
        # (Bash, Write ...) would widen the assistant's permissions.
        cmd = [*platform_support.cli_argv(path), "-p", "--model", settings.summary_model,
               "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "project"]
        if agentic:
            # Read-only and only inside ~/.claude: enforced by permission rules, not by a request in the prompt.
            # In -p mode anything not explicitly allowed is denied without asking.
            claude_dir = "/" + str(Path.home() / ".claude")  # "//Users/…" = absolute path in the rules
            cmd += ["--tools", "Read,Glob,Grep,ListAgents,SendMessage",
                    "--permission-mode", "default",
                    "--allowedTools", f"Read({claude_dir}/**)", f"Glob({claude_dir}/**)",
                    f"Grep({claude_dir}/**)", "ListAgents", "SendMessage",
                    "--add-dir", str(Path.home() / ".claude")]
        else:
            cmd += ["--tools", ""]
        # An empty folder of its own: with --setting-sources project, a .claude/settings.json left in the folder of a call
        # would be honoured. What discovery may read is given by --add-dir above.
        with tempfile.TemporaryDirectory(prefix="sozvon-claude-", ignore_cleanup_errors=True) as empty:
            def once(c):
                if on_event:
                    return _claude_stream(c, prompt, empty, timeout, on_event)
                r = _exec(c, prompt, input=prompt, timeout=timeout, cwd=empty)
                out = r.stdout.strip()
                if r.returncode != 0 or not out:
                    return None, name, (r.stderr or out)[:500]
                return out, name, ""
            res = once(cmd)
            if res[0] is None and OLD_CLAUDE_FLAG in res[2] and "unknown option" in res[2].lower():
                # An old Claude Code: the flag only keeps the session out of its history.
                res = once([a for a in cmd if a != OLD_CLAUDE_FLAG])
            return res

    if name == "cursor":
        return _cursor(path, prompt, agentic, timeout, settings)

    # codex exec: read-only sandbox, no session persistence, answer written to a file. A summary runs in an empty folder of
    # its own, not in the folder of the call; discovery runs where the sessions it has to read are.
    with tempfile.TemporaryDirectory(prefix="sozvon-codex-", ignore_cleanup_errors=True) as empty:
        workspace = str(cwd) if agentic else empty
        out_file = Path(empty) / "answer.txt"
        cmd = [*platform_support.cli_argv(path), "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
               "-C", workspace, "-o", str(out_file)]
        if settings.codex_model:
            cmd += ["-m", settings.codex_model]
        if not agentic:
            cmd += ["--ignore-rules"]
        cmd.append("-")
        r = _exec(cmd, prompt, input=prompt, timeout=timeout, cwd=workspace)
        out = out_file.read_text(encoding="utf-8").strip() if out_file.exists() else ""
    if r.returncode != 0 or not out:
        return None, name, (r.stderr or r.stdout)[-500:]
    return out, name, ""


OLD_CLAUDE_FLAG = "--no-session-persistence"
# An installed CLI that is logged out: how its error reads, and how to log in again.
LOGGED_OUT = ("oauth", "token has expired", "authentication", "not logged in", "login", "api key")
LOGIN = {"claude": "запусти claude в Терминале и набери /login", "codex": "codex login", "cursor": "cursor-agent login"}
# How to update each CLI, for a check that meets an option it does not know.
UPDATE = {"claude": "claude update", "codex": "brew upgrade codex или npm i -g @openai/codex", "cursor": "cursor-agent update"}
if platform_support.SYSTEM == "win32":
    UPDATE["codex"] = "npm i -g @openai/codex"


# Short argument for a summary: the request itself is in request.md, never in argv
# (a transcript can exceed the argument size limit and would show up in `ps`).
CURSOR_FILE_PROMPT = ("Read the file request.md in the current workspace and do exactly what it says. "
                      "Reply only with the answer it asks for, nothing else.")


# cursor-agent's answer where its sandbox does not run (some Macs): it refuses before reading anything.
NO_SANDBOX = "sandbox is unavailable"


def _cursor(path, prompt, agentic, timeout, settings):
    """cursor-agent -p in read-only ask mode with the sandbox on.

    agentic (project discovery): the short prompt goes as the argument, workspace ~/.cursor
    so it can read ~/.cursor/projects. Otherwise the prompt is written to request.md in a fresh
    temporary folder, which is the workspace.
    """
    cmd = [*platform_support.cli_argv(path), "-p", "--mode", "ask", "--sandbox", "enabled", "--trust", "--output-format", "text"]
    if settings.cursor_model:
        cmd += ["--model", settings.cursor_model]
    tmp = None
    try:
        if agentic:
            workspace = Path.home() / ".cursor"
            workspace.mkdir(exist_ok=True)
            arg = prompt
        else:
            tmp = tempfile.mkdtemp(prefix="sozvon-cursor-")
            workspace = Path(tmp)
            (workspace / "request.md").write_text(prompt, encoding="utf-8")
            arg = CURSOR_FILE_PROMPT
        cmd += ["--workspace", str(workspace), arg]
        try:
            r = _exec(cmd, prompt, stdin=subprocess.DEVNULL, timeout=timeout, cwd=str(workspace))
            if r.returncode != 0 and NO_SANDBOX in (r.stderr + r.stdout).lower():
                # Ask mode is read-only by itself; the sandbox only adds to it where it runs.
                plain = [a for i, a in enumerate(cmd) if a != "--sandbox" and (i == 0 or cmd[i - 1] != "--sandbox")]
                r = _exec(plain, prompt, stdin=subprocess.DEVNULL, timeout=timeout, cwd=str(workspace))
        except subprocess.TimeoutExpired:
            return None, "cursor", "timeout"
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    out = r.stdout.strip()
    if r.returncode != 0 or not out:
        return None, "cursor", (r.stderr or r.stdout)[-500:]
    return out, "cursor", ""


def _claude_stream(cmd, prompt, cwd, timeout, on_event):
    """claude -p in streaming mode: agent steps go to on_event, the answer text comes at the end."""
    cmd = cmd + ["--output-format", "stream-json", "--verbose"]
    # stderr to a file, not a pipe: an unread pipe fills up and claude hangs.
    errf = tempfile.TemporaryFile(mode="w+", **platform_support.TEXT_MODE)
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errf,
                            text=True, **platform_support.TEXT_MODE, cwd=str(cwd))
    proc.stdin.write(prompt)
    proc.stdin.close()
    result, err, start = None, "", time.time()
    for line in proc.stdout:
        if time.time() - start > timeout:
            proc.kill()
            journal(cmd, prompt, "timeout", time.time() - start)
            return None, "claude", "timeout"
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "assistant":
            for c in ev.get("message", {}).get("content", []):
                if c.get("type") == "tool_use":
                    on_event(c.get("name", ""), c.get("input") or {})
        elif ev.get("type") == "result":
            result = ev.get("result")
            if ev.get("is_error"):
                err = str(result)[:500]
    try:
        proc.wait(timeout=max(5, timeout - (time.time() - start)))
    except subprocess.TimeoutExpired:
        proc.kill()
        journal(cmd, prompt, "timeout", time.time() - start)
        return None, "claude", "timeout"
    if not result or err:
        errf.seek(0)
        err = err or errf.read()[:500]
        journal(cmd, prompt, proc.returncode, time.time() - start, err)
        return None, "claude", err
    journal(cmd, prompt, proc.returncode, time.time() - start)
    return str(result).strip(), "claude", ""


CHECK_PROMPT = "Reply with the single word OK."


def check(name: str, timeout: int = 120) -> tuple[bool, str]:
    """Does this assistant answer, through the very command a summary uses? -> (ok, its answer or the error)."""
    import tempfile as _t
    with _t.TemporaryDirectory(prefix="sozvon-check-") as d:
        out, _, err = run(CHECK_PROMPT, Path(d), timeout=timeout, only=name)
    if out:
        return True, out.strip()[:200]
    err = (err or "пустой ответ").strip()
    low = err.lower()
    if "unknown option" in low or "unknown argument" in low:
        err += f". Похоже, {BINARIES[name]} устарел, обнови: {UPDATE[name]}"
    elif any(w in low for w in LOGGED_OUT):
        err += f". Войди заново: {LOGIN[name]}"
    return False, err
