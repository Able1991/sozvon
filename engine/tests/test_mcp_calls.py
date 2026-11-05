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
    assert tools.search_calls("бюджет") == f"{cid}: [00:05] Анна: Бюджет согласован"
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
    assert names == {fn.__name__ for fn in tools.TOOLS}
    for t in asyncio.run(server.list_tools()):
        assert t.description and not any("Ѐ" <= ch <= "ӿ" for ch in t.description), t.name


def test_transcribe_tool_errors(data, tmp_path):
    assert tools.transcribe(str(tmp_path / "nope.wav")).startswith("ОШИБКА: файл не найден")
    f = tmp_path / "a.wav"
    f.write_bytes(b"x")
    assert "неизвестная модель" in tools.transcribe(str(f), model="medium")
    assert "не скачана" in tools.transcribe(str(f), model="turbo")
