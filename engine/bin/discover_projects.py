"""Discover the user's projects via Claude Code, Codex CLI or Cursor CLI and write them to profiles/.

Progress lines are "STATUS: ...", the last line is the result (docs/CONTRACT.md).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

if __name__ == "__main__":
    from sozvon_engine import discover, runtime
    runtime.prepare()
    sys.exit(discover.main())
