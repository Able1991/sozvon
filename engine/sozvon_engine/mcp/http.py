"""Общий MCP-сервер для всех сессий Claude и Codex: 127.0.0.1, пароль, жизнь вместе с Sozvon.

Защита в два слоя. Проверка Host и Origin в FastMCP (DNS rebinding) закрывает доступ сайтам из
браузера, bearer-токен (SOZVON_MCP_TOKEN, сравнение за постоянное время) остальным локальным
программам и страницам с localhost. Сервер дочерний для Sozvon и сам завершается, если
приложение упало: иначе сирота держит порт.
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
    """Проверка Host и Origin, stateless HTTP. Явно, а не по умолчанию FastMCP."""
    from mcp.server.transport_security import TransportSecuritySettings
    server.settings.host = HOST
    server.settings.port = port()
    server.settings.stateless_http = True
    server.settings.transport_security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True, allowed_hosts=ALLOWED_HOSTS, allowed_origins=ALLOWED_ORIGINS)


def with_token(inner, token: str):
    """ASGI-обёртка: HTTP-запрос без «Authorization: Bearer <token>» получает 401."""
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
    """Завершить процесс, когда родитель (Sozvon) пропал."""
    parent = os.getppid()
    if parent == 1:
        # Родитель уже умер (или запуск не из приложения через launchd): не занимать порт сиротой.
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
