"""Выбор и вызов Claude Code / Codex CLI (на поддельных бинарниках)."""
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
    # Поддельный codex: пишет ответ в файл после -o, как настоящий.
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
