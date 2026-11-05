#!/bin/bash
# All tests: Python (fast ones; SLOW=1 adds the end-to-end test on real Whisper), translations and Swift.
set -euo pipefail
cd "$(dirname "$0")"
echo "==> Python"
# ffmpeg from imageio-ffmpeg, as in setup.sh (a clean machine, e.g. CI, has no other)
(cd engine && uv sync --frozen -q && { [ -x .venv/bin/ffmpeg ] || ln -sf "$(.venv/bin/python -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')" .venv/bin/ffmpeg; })
if [ "${SLOW:-0}" = "1" ]; then (cd engine && uv run pytest -q); else (cd engine && uv run pytest -q -m "not slow"); fi
echo "==> Localization"
python3 tools/l10n.py check | tail -1
echo "==> Swift"
swift test
