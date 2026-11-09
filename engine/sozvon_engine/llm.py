"""Cloud assistant for summaries and project discovery: Claude Code, Codex CLI or Cursor CLI.

Choice: SOZVON_LLM = auto | claude | codex | cursor | none (default auto: the first
installed of claude, codex, cursor). Uses the user's subscription in the respective CLI.
Text goes to Anthropic (claude), OpenAI (codex) or Cursor and the model chosen there (cursor).
"""
import json
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from . import config, platform_support
from .i18n import t

BIN_DIRS = platform_support.tool_bin_dirs()


def _find(name: str):
    return platform_support.find_cli(name, BIN_DIRS)


# Backend name -> CLI binary, in auto-detection order.
BINARIES = {"claude": "claude", "codex": "codex", "cursor": "cursor-agent"}


def backend(settings: config.Settings | None = None):
    """-> ('claude'|'codex'|'cursor', path) or (None, None)."""
    want = (settings or config.load()).llm
    if want == "none":
        return None, None
    order = [want] if want in BINARIES else list(BINARIES)
    for name in order:
        if name in platform_support.UNVERIFIED_ASSISTANTS:
            if want == name:
                return name, None  # chosen: counts, so the failure reaches the call's warnings
            continue
        path = _find(BINARIES[name])
        if path:
            return name, path
    return None, None


def vendor(name) -> str:
    return {"claude": "Anthropic", "codex": "OpenAI", "cursor": "Cursor"}.get(name, "")


def run(prompt: str, cwd: Path, agentic: bool = False, timeout: int = 600, on_event=None):
    """Run a request. agentic=True: allow reading files (and Claude sessions).

    on_event(name, input): called on every agent step (claude only), for progress.
    -> (answer text, backend name, error or "").
    """
    settings = config.load()
    name, path = backend(settings)
    if not name:
        return None, None, "не найден ни claude, ни codex, ни cursor-agent CLI"
    if not path:
        return None, name, t("llm_unverified_assistant", name=name)
    if agentic and platform_support.AGENTIC_OFF:
        return None, name, t("llm_no_discovery")
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
            if on_event:
                return _claude_stream(cmd, prompt, empty, timeout, on_event)
            r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, **platform_support.TEXT_MODE,
                               timeout=timeout, cwd=empty)
        out = r.stdout.strip()
        if r.returncode != 0 or not out:
            return None, name, (r.stderr or out)[:500]
        return out, name, ""

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
        r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, **platform_support.TEXT_MODE,
                           timeout=timeout, cwd=workspace)
        out = out_file.read_text(encoding="utf-8").strip() if out_file.exists() else ""
    if r.returncode != 0 or not out:
        return None, name, (r.stderr or r.stdout)[-500:]
    return out, name, ""


# Short argument for a summary: the request itself is in request.md, never in argv
# (a transcript can exceed the argument size limit and would show up in `ps`).
CURSOR_FILE_PROMPT = ("Read the file request.md in the current workspace and do exactly what it says. "
                      "Reply only with the answer it asks for, nothing else.")


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
            r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, **platform_support.TEXT_MODE,
                               timeout=timeout, cwd=str(workspace))
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
        return None, "claude", "timeout"
    if not result or err:
        errf.seek(0)
        return None, "claude", err or errf.read()[:500]
    return str(result).strip(), "claude", ""
