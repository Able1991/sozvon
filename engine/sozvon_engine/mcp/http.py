"""Shared MCP server for all Claude, Codex and Cursor sessions: 127.0.0.1, password, lives as long as Sozvon.

Two layers of protection. The FastMCP Host and Origin check (DNS rebinding) blocks websites in the
browser; a bearer token (SOZVON_MCP_TOKEN, constant-time comparison) blocks other local
programs and localhost pages. The server is a child of Sozvon and exits on its own if the
app crashes: otherwise an orphan holds the port.
"""
import hmac
import os
import threading
import time

HOST = "127.0.0.1"
DEFAULT_PORT = 47816
ALLOWED_HOSTS = ["127.0.0.1:*", "localhost:*", "[::1]:*"]
ALLOWED_ORIGINS = ["http://127.0.0.1:*", "http://localhost:*", "http://[::1]:*"]


def port() -> int:
    return int(os.environ.get("SOZVON_MCP_PORT") or DEFAULT_PORT)


def protect(server) -> None:
    """Host and Origin check, stateless HTTP. Set explicitly instead of relying on FastMCP defaults."""
    from mcp.server.transport_security import TransportSecuritySettings
    server.settings.host = HOST
    server.settings.port = port()
    server.settings.stateless_http = True
    server.settings.transport_security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True, allowed_hosts=ALLOWED_HOSTS, allowed_origins=ALLOWED_ORIGINS)


def with_token(inner, token: str):
    """ASGI wrapper: an HTTP request without "Authorization: Bearer <token>" gets 401."""
    from starlette.responses import PlainTextResponse
    expected = f"Bearer {token}".encode("latin-1")

    async def app(scope, receive, send):
        if scope["type"] == "http":
            got = dict(scope.get("headers") or []).get(b"authorization", b"")
            if not hmac.compare_digest(got, expected):
                await PlainTextResponse("unauthorized", status_code=401)(scope, receive, send)
                return
        await inner(scope, receive, send)

    return app


def create_app(server, token: str):
    if not token:
        raise ValueError("empty token")
    protect(server)
    return with_token(server.streamable_http_app(), token)


def watch_parent(interval: float = 5.0) -> None:
    """Exit the process when the parent (Sozvon) is gone."""
    parent = os.getppid()
    if parent == 1:
        # The parent is already gone (or not launched from the app via launchd): do not hold the port as an orphan.
        os._exit(0)

    def loop():
        while True:
            time.sleep(interval)
            if os.getppid() != parent:
                os._exit(0)

    threading.Thread(target=loop, daemon=True).start()


def run(server) -> None:
    import uvicorn
    from ..i18n import t
    token = os.environ.get("SOZVON_MCP_TOKEN", "")
    if not token:
        raise SystemExit(t("mcp_no_token"))
    app = create_app(server, token)
    watch_parent()
    uvicorn.run(app, host=HOST, port=port(), log_level="warning")
