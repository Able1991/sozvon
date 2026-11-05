"""Облачный помощник для саммари и поиска проектов: Claude Code или Codex CLI.

Выбор: SOZVON_LLM = auto | claude | codex | none (по умолчанию auto: claude, если
установлен, иначе codex). Используется подписка пользователя в соответствующем CLI.
Текст уходит в Anthropic (claude) или OpenAI (codex).
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
    """-> ('claude'|'codex', путь) или (None, None)."""
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
    """Выполнить запрос. agentic=True: разрешить чтение файлов (и сессии Claude).

    on_event(name, input): вызывается на каждом шаге агента (только claude), для прогресса.
    -> (текст ответа, имя бэкенда, ошибка или "").
    """
    settings = config.load()
    name, path = backend(settings)
    if not name:
        return None, None, "не найден ни claude, ни codex CLI"
    if name == "claude":
        # --setting-sources project: без ~/.claude/settings.json, иначе allow-правила
        # пользователя (Bash, Write ...) расширили бы разрешения помощника.
        cmd = [path, "-p", "--model", settings.summary_model,
               "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "project"]
        if agentic:
            # Только чтение и только внутри ~/.claude: правила разрешений, а не просьба в промпте.
            # В режиме -p всё, что не разрешено явно, отклоняется без вопроса.
            claude_dir = "/" + str(Path.home() / ".claude")  # «//Users/…» = абсолютный путь в правилах
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

    # codex exec: read-only песочница, без сохранения сессии, ответ в файл.
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
    """claude -p в потоковом режиме: шаги агента идут в on_event, в конце текст ответа."""
    cmd = cmd + ["--output-format", "stream-json", "--verbose"]
    # stderr в файл, а не в трубу: непрочитанная труба заполняется, и claude зависает.
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
