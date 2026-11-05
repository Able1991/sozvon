"""Общий MCP-сервер: сторож родителя."""


def test_watch_parent_exits_when_orphaned(monkeypatch):
    from sozvon_engine.mcp import http
    calls = []
    monkeypatch.setattr(http.os, "getppid", lambda: 1)
    monkeypatch.setattr(http.os, "_exit", lambda code: calls.append(code))
    monkeypatch.setattr(http.threading, "Thread", lambda **kw: type("T", (), {"start": lambda self: None})())
    http.watch_parent()
    assert calls == [0]
