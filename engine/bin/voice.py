"""Voice prints: enroll a voice, list them, delete them (docs/CONTRACT.md, "Voice prints").

  python bin/voice.py enroll --name NAME [--profile SLUG] [--me] [--add] --file AUDIO
  python bin/voice.py enroll --name NAME [--profile SLUG] --call DIR --speaker LABEL
  python bin/voice.py list [--profile SLUG]
  python bin/voice.py delete --id ID | --all
Last output line: "RESULT: ok ..." or "RESULT: error <code> <message>".
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


def main() -> int:
    try:
        from sozvon_engine import runtime
        runtime.prepare()
        from sozvon_engine import voice_cli
    except ImportError as e:  # environment not built or broken
        msg = " ".join(f"engine is broken: {e}".split())
        print(msg, file=sys.stderr)
        print(f"RESULT: error 3 {msg}", flush=True)
        return 3
    return voice_cli.main()


if __name__ == "__main__":
    sys.exit(main())
