"""Sozvon MCP server: calls, transcripts, vocabulary and projects for Claude and Codex.

  python server.py          MCP over stdio (one assistant session)
  python server.py --http   shared server on 127.0.0.1:$SOZVON_MCP_PORT with token $SOZVON_MCP_TOKEN
Code lives in the sozvon_engine/ package, the app contract is in docs/CONTRACT.md.
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
