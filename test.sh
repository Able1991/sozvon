#!/bin/bash
# Все тесты: Python (быстрые; SLOW=1 добавит сквозной на настоящем Whisper), переводы и Swift.
set -euo pipefail
cd "$(dirname "$0")"
echo "==> Python"
if [ "${SLOW:-0}" = "1" ]; then (cd engine && uv run pytest -q); else (cd engine && uv run pytest -q -m "not slow"); fi
echo "==> Переводы"
python3 tools/l10n.py check | tail -1
echo "==> Swift"
swift test
