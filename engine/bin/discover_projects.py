"""Найти проекты пользователя через Claude Code или Codex CLI и записать их в profiles/.

Промежуточные строки «STATUS: …», последняя строка итог (docs/CONTRACT.md).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

if __name__ == "__main__":
    from sozvon_engine import discover, runtime
    runtime.prepare()
    sys.exit(discover.main())
