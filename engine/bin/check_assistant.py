"""Check that an assistant answers through the command a summary uses: check_assistant.py claude|codex|cursor.

The last line is `RESULT: ok <answer>` or `RESULT: error <message>` (docs/CONTRACT.md); exit 0 or 1.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

if __name__ == "__main__":
    from sozvon_engine import llm
    name = sys.argv[1] if len(sys.argv) > 1 else ""
    if name not in llm.BINARIES:
        print(f"RESULT: error usage: check_assistant.py {'|'.join(llm.BINARIES)}", flush=True)
        sys.exit(2)
    ok, message = llm.check(name)
    print(f"RESULT: {'ok' if ok else 'error'} {' '.join(message.split())}", flush=True)
    sys.exit(0 if ok else 1)
