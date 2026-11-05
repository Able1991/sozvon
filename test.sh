#!/bin/bash
# Все тесты: Python (быстрые; SLOW=1 добавит сквозной на настоящем Whisper), переводы и Swift.
set -euo pipefail
cd "$(dirname "$0")"
echo "==> Python"
# ffmpeg из imageio-ffmpeg, как в setup.sh (на чистой машине, например в CI, другого нет)
(cd engine && uv sync --frozen -q && { [ -x .venv/bin/ffmpeg ] || ln -sf "$(.venv/bin/python -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')" .venv/bin/ffmpeg; })
if [ "${SLOW:-0}" = "1" ]; then (cd engine && uv run pytest -q); else (cd engine && uv run pytest -q -m "not slow"); fi
echo "==> Localization"
python3 tools/l10n.py check | tail -1
echo "==> Swift"
swift test
