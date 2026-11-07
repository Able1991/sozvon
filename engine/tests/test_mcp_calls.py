"""MCP call tools: Claude sees recordings, summaries and transcripts."""
import json

import pytest

from sozvon_engine.mcp import tools


@pytest.fixture
def calls(tmp_path, profiles):
    (profiles / "acme.json").write_text(json.dumps({"title": "Acme Corp"}))
    root = tmp_path / "Calls"
    a = root / "2026-11-04 15-01 · Acme · запуск · Анна"
    a.mkdir(parents=True)
    (a / "call.json").write_text(json.dumps({"profile": "acme", "names": ["Анна"], "topic": "запуск"}, ensure_ascii=False))
    (a / "meta.json").write_text(json.dumps({"mic_seconds": 125.0}))
    (a / "summary.md").write_text("## Коротко\nДоговорились запустить в понедельник.")
    (a / "transcript.txt").write_text("[00:01] Я: Привет\n[00:05] Анна: Бюджет согласован\n")
    (root / "2026-11-03 10-00").mkdir()
    return root


def test_list_calls(calls):
    lines = tools.list_calls().splitlines()
    assert lines[0].startswith("- 2026-11-04 15-01:") and "Acme Corp" in lines[0] and "Анна" in lines[0]
    assert "02:05" in lines[0] and "саммари" in lines[0]
    assert "без расшифровки" in lines[1]
    assert lines[0] == "- 2026-11-04 15-01: запуск · Acme Corp · Анна · 02:05 · саммари"
    assert lines[1] == "- 2026-11-03 10-00: без расшифровки", "no date twice, no placeholder for a missing topic"


def test_list_calls_query_matches_text(calls):
    assert "15-01" in tools.list_calls("понедельник")
    assert tools.list_calls("несуществующее") == "Звонков не найдено."


def test_list_calls_english(calls, monkeypatch):
    monkeypatch.setenv("SOZVON_UI_LANG", "en")
    assert tools.list_calls("nothing") == "No calls found."
    assert "summary" in tools.list_calls().splitlines()[0]


def test_get_call_and_search(calls):
    cid = "2026-11-04 15-01"  # stable id: the recording date, unchanged when the folder is renamed
    assert "понедельник" in tools.get_call(cid)
    both = tools.get_call(cid, "both")
    assert "Бюджет согласован" in both and "Коротко" in both
    assert tools.search_calls("бюджет") == f"{cid}: [00:05] Анна: Бюджет согласован (запуск · Acme Corp)"
    # the old full folder name is accepted too
    assert "понедельник" in tools.get_call("2026-11-04 15-01 · Acme · запуск · Анна")


def test_id_survives_folder_rename(calls):
    old = calls / "2026-11-04 15-01 · Acme · запуск · Анна"
    old.rename(calls / "2026-11-04 15-01 · Acme · запуск · Анна, Иван")
    assert "понедельник" in tools.get_call("2026-11-04 15-01")


def test_get_call_rejects_paths_outside(calls):
    with pytest.raises(ValueError):
        tools.get_call("../../etc")


def test_server_registers_all_tools():
    import asyncio
    server = tools.build_server()
    names = {t.name for t in asyncio.run(server.list_tools())}
    assert names == {fn.__name__ for fn in tools.TOOLS} | {"add_note", "delete_note"}
    note = next(t for t in asyncio.run(server.list_tools()) if t.name == "add_note")
    assert set(note.inputSchema["properties"]) == {"call_id", "text"}, "the context is not an argument"
    assert "Sozvon app" in note.description
    for t in asyncio.run(server.list_tools()):
        assert t.description and not any("Ѐ" <= ch <= "ӿ" for ch in t.description), t.name


def test_transcribe_tool_errors(data, tmp_path):
    assert tools.transcribe(str(tmp_path / "nope.wav")).startswith("ОШИБКА: файл не найден")
    f = tmp_path / "a.wav"
    f.write_bytes(b"x")
    assert "неизвестная модель" in tools.transcribe(str(f), model="medium")
    assert "не скачана" in tools.transcribe(str(f), model="turbo")


def test_add_note_and_get_call(calls, monkeypatch):
    sent = []
    monkeypatch.setattr(tools, "_push_notes_later", lambda d: sent.append(d.name))
    cid = "2026-11-04 15-01"
    assert tools.add_note(cid, "  Перезвонить Анне в пятницу  ", source="claude-code") == (
        f"Заметка добавлена к звонку {cid}. Она видна в приложении Sozvon.")
    assert sent == ["2026-11-04 15-01 · Acme · запуск · Анна"]
    tools.add_note(cid, "second", source="")
    c = json.loads((calls / sent[0] / "call.json").read_text())
    assert [n["text"] for n in c["notes"]] == ["Перезвонить Анне в пятницу", "second"]
    assert [n["source"] for n in c["notes"]] == ["claude-code", "assistant"]
    assert c["topic"] == "запуск" and c["names"] == ["Анна"], "other call.json fields are kept"
    assert len(c["notes"][0]["id"]) == 36 and c["notes"][0]["at"].endswith("Z")
    for part in ("summary", "transcript", "both"):
        out = tools.get_call(cid, part)
        assert "## Заметки\n- " in out and f"· claude-code · {c['notes'][0]['id']}: Перезвонить Анне в пятницу" in out, part
    assert "заметок: 2" in tools.list_calls().splitlines()[0]
    assert "заметок" not in tools.list_calls().splitlines()[1]
    assert "15-01" in tools.list_calls("пятницу"), "list_calls filters by note text too"
    hits = tools.search_calls("перезвонить пятница")
    assert hits.startswith(f"{cid}: [заметка 20") and "claude-code: Перезвонить Анне в пятницу" in hits


def test_delete_note(calls, monkeypatch):
    sent = []
    monkeypatch.setattr(tools, "_push_notes_later", lambda d: sent.append(d.name))
    cid = "2026-11-04 15-01"
    tools.add_note(cid, "keep")
    tools.add_note(cid, "drop")
    f = calls / sent[0] / "call.json"
    keep, drop = (n["id"] for n in json.loads(f.read_text())["notes"])
    assert tools.delete_note(cid, f" {drop} ") == f"Заметка {drop} удалена у звонка {cid}."
    c = json.loads(f.read_text())
    assert [n["id"] for n in c["notes"]] == [keep] and c["notes_deleted"] == [drop], "a tombstone for sync"
    assert len(sent) == 3, "the deletion is pushed to the own server"
    assert tools.delete_note(cid, drop).startswith("ОШИБКА: нет заметки")
    assert tools.delete_note(cid, "../x").startswith("ОШИБКА: нет заметки")
    assert "drop" not in tools.get_call(cid, "both")


def test_add_note_limits(calls, monkeypatch):
    from sozvon_engine import notes
    monkeypatch.setattr(tools, "_push_notes_later", lambda d: None)
    cid = "2026-11-04 15-01"
    assert tools.add_note(cid, "   ").startswith("ОШИБКА: пустая заметка")
    assert tools.add_note(cid, "x" * 4001).startswith("ОШИБКА: заметка длиннее 4000")
    assert "добавлена" in tools.add_note(cid, "я" * 4000)
    monkeypatch.setattr(notes, "MAX_NOTES", 2)
    tools.add_note(cid, "two")
    assert tools.add_note(cid, "three").startswith("ОШИБКА: у звонка уже 2 заметок")
    with pytest.raises(ValueError):
        tools.add_note("../../etc", "x")


def test_add_note_keeps_a_broken_call_json(calls, monkeypatch):
    monkeypatch.setattr(tools, "_push_notes_later", lambda d: None)
    d = calls / "2026-11-03 10-00"
    (d / "call.json").write_text("{broken")
    with pytest.raises(ValueError):
        tools.add_note("2026-11-03 10-00", "x")
    assert (d / "call.json").read_text() == "{broken"


def test_source_names():
    from sozvon_engine.notes import source_name
    assert source_name("claude-code") == "claude-code"
    assert source_name("Claude Code/2.1") == "claude-code"
    assert source_name("codex-mcp-client") == "codex"
    assert source_name("claude-ai") == "claude"
    assert source_name("ChatGPT") == "chatgpt"
    assert source_name("openai-mcp") == "chatgpt"
    assert source_name("My Tool!!") == "my-tool"
    assert source_name("") == source_name(None) == "assistant"
    assert len(source_name("x" * 100)) == 40


def test_client_name_from_context():
    from types import SimpleNamespace as NS
    ctx = NS(session=NS(client_params=NS(clientInfo=NS(name="claude-code"))))
    assert tools.client_name(ctx) == "claude-code"
    stateless = NS(session=NS(client_params=None),
                   request_context=NS(request=NS(headers={"user-agent": "codex_cli_rs/0.50"})))
    assert tools.client_name(stateless) == "codex_cli_rs/0.50"
    assert tools.client_name(None) == ""


def test_notes_merge_and_tombstones(tmp_path):
    from sozvon_engine import notes
    d = tmp_path / "c"
    d.mkdir()
    (d / "call.json").write_text(json.dumps({"schema": 1, "id": "2026-11-04 15-01", "notes": [
        {"id": "a", "at": "2026-11-04T10:00:00Z", "text": "local", "source": "app"},
        {"id": "bad id!", "at": "x", "text": "dropped", "source": "app"}]}))
    remote_note = {"id": "b", "at": "2026-11-04T09:00:00Z", "text": "from server", "source": "claude", "extra": 1}
    assert notes.merge(d, [remote_note], []) is True
    c = json.loads((d / "call.json").read_text())
    assert [n["id"] for n in c["notes"]] == ["b", "a"] and "extra" not in c["notes"][0]
    assert notes.merge(d, [remote_note], []) is False, "nothing new: call.json is not rewritten"
    assert notes.merge(d, [], ["a"]) is True
    c = json.loads((d / "call.json").read_text())
    assert [n["id"] for n in c["notes"]] == ["b"] and c["notes_deleted"] == ["a"]
    assert notes.merge(d, [{"id": "a", "at": "2026", "text": "zombie", "source": "x"}], []) is False, \
        "a tombstoned note never comes back"


def test_transcribe_tool_auto_language_and_word_times(data, tmp_path, monkeypatch):
    from conftest import fake_model
    from sozvon_engine import prompt, whisper
    fake_model(data)
    monkeypatch.setattr(prompt, "count_tokens", lambda text: len(text.split()))
    seen = {}

    def fake(path, model_path, language, p, fb, **kw):
        seen.update(kw, language=language)
        return [{"start": 0.0, "end": 9.0, "text": " Привет. Да.",
                 "words": [{"start": 7.0, "end": 7.5, "word": " Привет."}, {"start": 8.0, "end": 8.3, "word": " Да."}]}], p
    monkeypatch.setattr(whisper, "whisper_with_fallback", fake)
    f = tmp_path / "a.wav"
    f.write_bytes(b"x")
    assert tools.transcribe(str(f), language="auto") == "[00:07] Привет.\n[00:08] Да."
    assert seen["language"] is None and seen["word_timestamps"] is True
