"""Cloud assistant for summaries and project discovery: Claude Code or Codex CLI.

Choice: SOZVON_LLM = auto | claude | codex | none (default auto: claude if
installed, otherwise codex). Uses the user's subscription in the respective CLI.
Text goes to Anthropic (claude) or OpenAI (codex).
"""
import json
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from . import config

BIN_DIRS = [Path.home() / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin")]


def _find(name: str):
    p = shutil.which(name)
    if p:
        return p
    for d in BIN_DIRS:
        if (d / name).exists():
            return str(d / name)
    return None


def backend(settings: config.Settings | None = None):
    """-> ('claude'|'codex', path) or (None, None)."""
    want = (settings or config.load()).llm
    if want == "none":
        return None, None
    order = [want] if want in ("claude", "codex") else ["claude", "codex"]
    for name in order:
        path = _find(name)
        if path:
            return name, path
    return None, None


def vendor(name) -> str:
    return {"claude": "Anthropic", "codex": "OpenAI"}.get(name, "")


def run(prompt: str, cwd: Path, agentic: bool = False, timeout: int = 600, on_event=None):
    """Run a request. agentic=True: allow reading files (and Claude sessions).

    on_event(name, input): called on every agent step (claude only), for progress.
    -> (answer text, backend name, error or "").
    """
    settings = config.load()
    name, path = backend(settings)
    if not name:
        return None, None, "не найден ни claude, ни codex CLI"
    if name == "claude":
        # --setting-sources project: skip ~/.claude/settings.json, otherwise the user's allow rules
        # (Bash, Write ...) would widen the assistant's permissions.
        cmd = [path, "-p", "--model", settings.summary_model,
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
        if on_event:
            return _claude_stream(cmd, prompt, cwd, timeout, on_event)
        r = subprocess.run(cmd, input=prompt, capture_output=True, text=True,
                           timeout=timeout, cwd=str(cwd))
        out = r.stdout.strip()
        if r.returncode != 0 or not out:
            return None, name, (r.stderr or out)[:500]
        return out, name, ""

    # codex exec: read-only sandbox, no session persistence, answer written to a file.
    with tempfile.NamedTemporaryFile("r", suffix=".txt", delete=False) as tf:
        out_file = tf.name
    cmd = [path, "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
           "-C", str(cwd), "-o", out_file]
    if settings.codex_model:
        cmd += ["-m", settings.codex_model]
    if not agentic:
        cmd += ["--ignore-rules"]
    cmd.append("-")
    try:
        r = subprocess.run(cmd, input=prompt, capture_output=True, text=True,
                           timeout=timeout, cwd=str(cwd))
        out = Path(out_file).read_text(encoding="utf-8").strip() if Path(out_file).exists() else ""
    finally:
        Path(out_file).unlink(missing_ok=True)
    if r.returncode != 0 or not out:
        return None, name, (r.stderr or r.stdout)[-500:]
    return out, name, ""


def _claude_stream(cmd, prompt, cwd, timeout, on_event):
    """claude -p in streaming mode: agent steps go to on_event, the answer text comes at the end."""
    cmd = cmd + ["--output-format", "stream-json", "--verbose"]
    # stderr to a file, not a pipe: an unread pipe fills up and claude hangs.
    errf = tempfile.TemporaryFile(mode="w+")
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errf,
                            text=True, cwd=str(cwd))
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
