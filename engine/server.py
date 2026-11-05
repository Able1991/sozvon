"""MCP-сервер Sozvon: звонки, расшифровки, словарь и проекты для Claude и Codex.

  python server.py          MCP по stdio (одна сессия помощника)
  python server.py --http   общий сервер на 127.0.0.1:$SOZVON_MCP_PORT с паролем $SOZVON_MCP_TOKEN
Код в пакете sozvon_engine/, договор с приложением в docs/CONTRACT.md.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sozvon_engine import runtime  # noqa: E402


def main(argv=None) -> None:
    argv = sys.argv[1:] if argv is None else argv
    runtime.prepare()
    from sozvon_engine.mcp import tools
    server = tools.build_server()
    if "--http" in argv:
        from sozvon_engine.mcp import http
        http.run(server)
    else:
        server.run()


if __name__ == "__main__":
    main()
