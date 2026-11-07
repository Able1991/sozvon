"""Transcribe a Sozvon call folder: everything about the call is read from call.json.

  python bin/process_call.py "<call folder>" [--profile acme] [--names "Anna,Ivan"] [--topic ...]
      [--terms ...] [--language ru,en] [--speakers N] [--switch] [--no-diarize] [--no-summary] [--me ...]
Last output line: "RESULT: ok" or "RESULT: error <code> <message>" (docs/CONTRACT.md).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


def main() -> int:
    try:
        from sozvon_engine import runtime
        runtime.prepare()
        from sozvon_engine.pipeline import run
    except ImportError as e:  # environment not built or broken
        try:
            from sozvon_engine.i18n import t
            msg = t("err_engine", err=e)
        except ImportError:
            msg = f"engine is broken: {e}"
        msg = " ".join(msg.split())
        print(msg, file=sys.stderr)
        print(f"RESULT: error 3 {msg}", flush=True)
        return 3
    return run.main()


if __name__ == "__main__":
    sys.exit(main())
