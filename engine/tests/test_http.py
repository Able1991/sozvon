"""Shared MCP server: password and protection from websites in the browser."""
import pytest
from starlette.testclient import TestClient

from sozvon_engine.mcp import http, tools

TOKEN = "s3cret-token"
INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-03-26", "capabilities": {},
                   "clientInfo": {"name": "test", "version": "1"}}}
HEADERS = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}


@pytest.fixture
def client():
    app = http.create_app(tools.build_server(), TOKEN)
    with TestClient(app, base_url="http://127.0.0.1:47816") as c:
        yield c


def test_no_token_is_401(client):
    assert client.post("/mcp", json=INIT, headers=HEADERS).status_code == 401


def test_wrong_token_is_401(client):
    for value in ("Bearer nope", f"Bearer {TOKEN}x", TOKEN, f"bearer {TOKEN}"):
        r = client.post("/mcp", json=INIT, headers={**HEADERS, "Authorization": value})
        assert r.status_code == 401, value


def test_right_token_is_200(client):
    r = client.post("/mcp", json=INIT, headers={**HEADERS, "Authorization": f"Bearer {TOKEN}"})
    assert r.status_code == 200, r.text
    assert "serverInfo" in r.text and "sozvon" in r.text


def test_foreign_origin_is_403(client):
    r = client.post("/mcp", json=INIT, headers={**HEADERS, "Authorization": f"Bearer {TOKEN}",
                                                 "Origin": "https://evil.example"})
    assert r.status_code == 403


def test_foreign_host_is_rejected():
    app = http.create_app(tools.build_server(), TOKEN)
    with TestClient(app, base_url="http://evil.example") as c:
        r = c.post("/mcp", json=INIT, headers={**HEADERS, "Authorization": f"Bearer {TOKEN}"})
        assert r.status_code in (403, 421)


def test_empty_token_refused(monkeypatch):
    with pytest.raises(ValueError):
        http.create_app(tools.build_server(), "")
    monkeypatch.delenv("SOZVON_MCP_TOKEN", raising=False)
    with pytest.raises(SystemExit):
        http.run(tools.build_server())
