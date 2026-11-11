"""Choosing and calling Claude Code / Codex / Cursor CLI (with fake binaries)."""
import stat
from pathlib import Path

import pytest

from sozvon_engine import llm


def fake_cli(dirpath: Path, name: str, script: str) -> Path:
    p = dirpath / name
    p.write_text("#!/bin/bash\n" + script)
    p.chmod(p.stat().st_mode | stat.S_IEXEC)
    return p


@pytest.fixture
def bins(tmp_path, monkeypatch):
    d = tmp_path / "bin"
    d.mkdir()
    monkeypatch.setattr(llm, "BIN_DIRS", [d])
    monkeypatch.setenv("PATH", f"{d}:/usr/bin:/bin")
    monkeypatch.delenv("SOZVON_LLM", raising=False)
    return d


def test_nothing_installed(bins):
    assert llm.backend() == (None, None)
    out, name, err = llm.run("x", bins)
    assert out is None and name is None and err


def test_auto_prefers_claude(bins):
    fake_cli(bins, "claude", "cat >/dev/null; echo hi")
    fake_cli(bins, "codex", "echo hi")
    assert llm.backend()[0] == "claude"


def test_auto_falls_back_to_codex(bins):
    fake_cli(bins, "codex", "echo hi")
    assert llm.backend()[0] == "codex"


def test_explicit_choice_and_none(bins, monkeypatch):
    fake_cli(bins, "claude", "echo hi")
    fake_cli(bins, "codex", "echo hi")
    monkeypatch.setenv("SOZVON_LLM", "codex")
    assert llm.backend()[0] == "codex"
    monkeypatch.setenv("SOZVON_LLM", "none")
    assert llm.backend() == (None, None)


def test_explicit_choice_not_installed(bins, monkeypatch):
    fake_cli(bins, "claude", "echo hi")
    monkeypatch.setenv("SOZVON_LLM", "codex")
    assert llm.backend() == (None, None)


def test_claude_gets_prompt_on_stdin_and_no_tools(bins, tmp_path):
    log = tmp_path / "args"
    fake_cli(bins, "claude", f'echo "$@" > {log}; cat')
    out, name, err = llm.run("ПРОМПТ", tmp_path)
    assert (out, name, err) == ("ПРОМПТ", "claude", "")
    args = log.read_text()
    assert "-p" in args and "--tools" in args and "--no-session-persistence" in args
    assert "bypassPermissions" not in args


def test_claude_agentic_is_read_only(bins, tmp_path):
    log = tmp_path / "args"
    fake_cli(bins, "claude", f'echo "$@" > {log}; cat >/dev/null; echo ok')
    llm.run("x", tmp_path, agentic=True)
    args = log.read_text()
    assert "Read,Glob,Grep,ListAgents,SendMessage" in args
    assert "--setting-sources project" in args, "правила из ~/.claude/settings.json не расширяют доступ"
    for bad in ("Bash", "Write", "Edit"):
        assert bad not in args


def test_codex_reads_answer_from_output_file(bins, tmp_path):
    log = tmp_path / "args"
    # Fake codex: writes the answer to the file after -o, like the real one.
    fake_cli(bins, "codex", f'''echo "$@" > {log}
prompt=$(cat)
while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then out="$2"; fi; shift; done
echo "ответ на: $prompt" > "$out"''')
    out, name, err = llm.run("вопрос", tmp_path)
    assert name == "codex" and out == "ответ на: вопрос" and err == ""
    args = log.read_text()
    assert "exec" in args and "read-only" in args and "--ephemeral" in args


def test_failure_returns_error(bins, tmp_path):
    fake_cli(bins, "claude", "cat >/dev/null; echo boom >&2; exit 3")
    out, name, err = llm.run("x", tmp_path)
    assert out is None and name == "claude" and "boom" in err


def test_vendor():
    assert llm.vendor("claude") == "Anthropic" and llm.vendor("codex") == "OpenAI"
    assert llm.vendor("cursor") == "Cursor"


def test_auto_falls_back_to_cursor(bins):
    fake_cli(bins, "cursor-agent", "echo hi")
    assert llm.backend()[0] == "cursor"
    fake_cli(bins, "codex", "echo hi")
    assert llm.backend()[0] == "codex", "codex раньше cursor"


def test_explicit_cursor(bins, monkeypatch):
    fake_cli(bins, "claude", "echo hi")
    fake_cli(bins, "cursor-agent", "echo hi")
    monkeypatch.setenv("SOZVON_LLM", "cursor")
    name, path = llm.backend()
    assert name == "cursor" and path.endswith("/cursor-agent")


# Fake cursor-agent: logs its arguments (one per line) and working dir, copies request.md to keep it
# for the test, answers with the file content or the prompt argument (the last one).
CURSOR_FAKE = """printf '%s\n' "$@" > {log}
pwd > {cwd}
ws=""; prev=""
for a in "$@"; do if [ "$prev" = "--workspace" ]; then ws="$a"; fi; prev="$a"; done
echo "$ws" > {ws}
if [ -f "$ws/request.md" ]; then cp "$ws/request.md" {req}; echo "ответ на: $(cat "$ws/request.md")"
else echo "agentic: ${{@: -1}}"; fi
"""


def cursor_fake(bins, tmp_path):
    files = {k: tmp_path / k for k in ("log", "cwd", "ws", "req")}
    fake_cli(bins, "cursor-agent", CURSOR_FAKE.format(**files))
    return files


def test_cursor_summary_prompt_goes_through_request_md(bins, tmp_path, monkeypatch):
    monkeypatch.setenv("SOZVON_LLM", "cursor")
    monkeypatch.setenv("SOZVON_CURSOR_MODEL", "sonnet-4")
    f = cursor_fake(bins, tmp_path)
    long_prompt = "РАСШИФРОВКА " * 20000
    out, name, err = llm.run(long_prompt, tmp_path)
    assert name == "cursor" and err == "" and out == "ответ на: " + long_prompt.strip()
    args = f["log"].read_text().splitlines()
    ws = f["ws"].read_text().strip()
    assert args[:9] == ["-p", "--mode", "ask", "--sandbox", "enabled", "--trust", "--output-format", "text",
                        "--model"] and args[9] == "sonnet-4"
    assert args[-3:] == ["--workspace", ws, llm.CURSOR_FILE_PROMPT]
    assert "РАСШИФРОВКА" not in "".join(args), "текст звонка не в аргументах"
    assert f["req"].read_text() == long_prompt
    assert Path(f["cwd"].read_text().strip()).resolve() == Path(ws).resolve()
    assert ws != str(tmp_path) and not Path(ws).exists(), "временная папка удалена"
    for bad in ("--force", "--yolo", "--approve-mcps"):
        assert bad not in args


def test_cursor_without_model_and_agentic(bins, tmp_path, monkeypatch):
    monkeypatch.setenv("SOZVON_LLM", "cursor")
    monkeypatch.setenv("HOME", str(tmp_path))
    f = cursor_fake(bins, tmp_path)
    out, name, err = llm.run("найди проекты", tmp_path, agentic=True)
    assert (out, name, err) == ("agentic: найди проекты", "cursor", "")
    args = f["log"].read_text().splitlines()
    assert "--model" not in args and "--mode" in args and args[args.index("--mode") + 1] == "ask"
    assert args[-3:] == ["--workspace", str(Path.home() / ".cursor"), "найди проекты"]
    assert not f["req"].exists()


def test_cursor_failure_and_timeout(bins, tmp_path, monkeypatch):
    monkeypatch.setenv("SOZVON_LLM", "cursor")
    fake_cli(bins, "cursor-agent", "echo boom >&2; exit 2")
    out, name, err = llm.run("x", tmp_path)
    assert out is None and name == "cursor" and "boom" in err
    fake_cli(bins, "cursor-agent", "exec sleep 5")
    assert llm.run("x", tmp_path, timeout=1) == (None, "cursor", "timeout")


def test_claude_stream_reports_steps_and_result(bins, tmp_path):
    events = [
        '{"type":"system","subtype":"init"}',
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ListAgents","input":{}}]}}',
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SendMessage","input":{"to":"acme"}}]}}',
        'not json',
        '{"type":"result","subtype":"success","result":"[{\\"slug\\":\\"a\\"}]"}',
    ]
    script = "cat >/dev/null\n" + "".join(f"echo '{e}'\n" for e in events)
    fake_cli(bins, "claude", script)
    seen = []
    out, name, err = llm.run("x", tmp_path, agentic=True, on_event=lambda t, i: seen.append((t, i)))
    assert (out, name, err) == ('[{"slug":"a"}]', "claude", "")
    assert seen == [("ListAgents", {}), ("SendMessage", {"to": "acme"})]


def test_claude_never_gets_mcp_servers(bins, tmp_path):
    log = tmp_path / "args"
    fake_cli(bins, "claude", f'echo "$@" > {log}; cat >/dev/null; echo ok')
    llm.run("x", tmp_path)
    assert "--strict-mcp-config" in log.read_text()
    llm.run("x", tmp_path, agentic=True)
    assert "--strict-mcp-config" in log.read_text()


# Where Cursor's sandbox does not run, cursor-agent refuses before reading anything: "sandbox is enabled but not
# available on this system". Ask mode is read-only by itself: the same request goes again without the sandbox.
NO_SANDBOX_FAKE = """printf '%s\\n' "$@" >> {log}; echo --- >> {log}
for a in "$@"; do if [ "$a" = "--sandbox" ]; then echo "Error: sandbox is enabled but not available on this system. Sandbox is unavailable" >&2; exit 1; fi; done
echo "готово"
"""


def test_cursor_without_a_sandbox_asks_again_in_read_only_mode(bins, tmp_path, monkeypatch):
    monkeypatch.setenv("SOZVON_LLM", "cursor")
    log = tmp_path / "log"
    fake_cli(bins, "cursor-agent", NO_SANDBOX_FAKE.format(log=log))
    assert llm.run("саммари", tmp_path) == ("готово", "cursor", "")
    first, second = [c.split("\n") for c in log.read_text().strip().split("\n---") if c.strip()][:2]
    assert "--sandbox" in first and "--sandbox" not in [a for a in second if a]
    second = [a for a in second if a]
    assert second[second.index("--mode") + 1] == "ask"
    for bad in ("--force", "--yolo", "--approve-mcps"):
        assert bad not in second


def test_other_cursor_errors_are_not_retried(bins, tmp_path, monkeypatch):
    monkeypatch.setenv("SOZVON_LLM", "cursor")
    log = tmp_path / "log"
    fake_cli(bins, "cursor-agent", f"echo call >> {log}; echo 'Error: Authentication required' >&2; exit 1")
    out, name, err = llm.run("x", tmp_path)
    assert out is None and "Authentication" in err and log.read_text().count("call") == 1


# Every assistant call leaves one line in <data>/assistant.log (the diagnostics zip takes it): which CLI, how it
# was called, how it ended. Never the request itself: a transcript, or a project prompt passed as an argument.

def journal(data):
    return (data / "assistant.log").read_text(encoding="utf-8")


def test_a_failed_call_is_in_the_journal_without_the_request(bins, tmp_path, monkeypatch, data):
    monkeypatch.setenv("SOZVON_LLM", "cursor")
    fake_cli(bins, "cursor-agent", "echo 'Error: Authentication required' >&2; exit 1")
    llm.run("Секретная РАСШИФРОВКА звонка", tmp_path)
    llm.run("найди проекты: Секретный клиент", tmp_path, agentic=True)
    text = journal(data)
    assert text.count("cursor-agent") == 2 and "--mode ask" in text and "exit 1" in text
    assert "Authentication required" in text
    assert "Секрет" not in text and "<request>" in text


def test_a_good_call_is_in_the_journal_too(bins, tmp_path, monkeypatch, data):
    fake_cli(bins, "claude", "cat >/dev/null; echo ответ")
    assert llm.run("Секретный текст", tmp_path)[0] == "ответ"
    text = journal(data)
    assert "claude -p" in text and "exit 0" in text and "Секрет" not in text


def test_the_sandbox_retry_shows_as_two_calls(bins, tmp_path, monkeypatch, data):
    monkeypatch.setenv("SOZVON_LLM", "cursor")
    fake_cli(bins, "cursor-agent", NO_SANDBOX_FAKE.format(log=tmp_path / "log"))
    llm.run("x", tmp_path)
    lines = [ln for ln in journal(data).splitlines() if "cursor-agent" in ln]
    assert len(lines) == 2 and "--sandbox" in lines[0] and "--sandbox" not in lines[1]


# The app checks the chosen assistant right when it is picked: the same command a summary uses, a tiny request.

def test_check_runs_the_chosen_assistant_not_the_first_installed(bins, tmp_path):
    fake_cli(bins, "claude", "cat >/dev/null; echo OK")
    fake_cli(bins, "cursor-agent", "echo 'Error: Authentication required' >&2; exit 1")
    ok, message = llm.check("cursor")
    assert not ok and "Authentication required" in message
    assert llm.check("claude") == (True, "OK")


def test_check_names_a_missing_cli(bins):
    ok, message = llm.check("codex")
    assert not ok and "codex" in message


def test_check_does_not_accept_an_empty_answer(bins):
    fake_cli(bins, "claude", "cat >/dev/null; exit 0")
    ok, message = llm.check("claude")
    assert not ok and message


# An old Claude Code does not know --no-session-persistence ("error: unknown option"): the flag only keeps the
# session out of its history, so the request goes again without it.
OLD_CLAUDE = """cat >/dev/null
printf '%s\\n' "$@" >> {log}; echo --- >> {log}
for a in "$@"; do if [ "$a" = "--no-session-persistence" ]; then echo "error: unknown option '--no-session-persistence'" >&2; exit 1; fi; done
echo ответ
"""


def test_an_old_claude_without_session_persistence_flag_is_asked_again(bins, tmp_path):
    log = tmp_path / "log"
    fake_cli(bins, "claude", OLD_CLAUDE.format(log=log))
    assert llm.run("x", tmp_path) == ("ответ", "claude", "")
    calls = [c for c in log.read_text().split("---") if c.strip()]
    assert len(calls) == 2 and "--no-session-persistence" not in calls[1] and "--tools" in calls[1]


def test_a_check_of_an_outdated_cli_says_to_update_it(bins):
    fake_cli(bins, "claude", "cat >/dev/null; echo \"error: unknown option '--setting-sources'\" >&2; exit 1")
    ok, message = llm.check("claude")
    assert not ok and "--setting-sources" in message and "claude update" in message


# A CLI that is installed but logged out (an expired login) answers with an error: the check says how to log in.

@pytest.mark.parametrize("name,binary,error,hint", [
    ("claude", "claude", "OAuth token has expired. Please obtain a new token or refresh your existing token.", "/login"),
    ("claude", "claude", "Invalid API key · Please run /login", "/login"),
    ("cursor", "cursor-agent", "Error: Authentication required. Please run 'agent login' first", "cursor-agent login"),
    ("codex", "codex", "Not logged in. Run codex login", "codex login"),
])
def test_a_check_of_a_logged_out_cli_says_how_to_log_in(bins, monkeypatch, name, binary, error, hint):
    fake_cli(bins, binary, f"cat >/dev/null; echo '{error}' >&2; exit 1")
    ok, message = llm.check(name)
    assert not ok and error[:20] in message and hint in message
