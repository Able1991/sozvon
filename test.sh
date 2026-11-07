#!/bin/bash
# All tests: Python (fast ones; SLOW=1 adds the end-to-end test on real Whisper), translations, the server
# (Node.js 22+; required in CI, skipped locally without it) and Swift.
set -euo pipefail
cd "$(dirname "$0")"
echo "==> Python"
# ffmpeg from imageio-ffmpeg, as in setup.sh (a clean machine, e.g. CI, has no other)
(cd engine && uv sync --frozen -q && { [ -x .venv/bin/ffmpeg ] || ln -sf "$(.venv/bin/python -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')" .venv/bin/ffmpeg; })
if [ "${SLOW:-0}" = "1" ]; then (cd engine && uv run pytest -q); else (cd engine && uv run pytest -q -m "not slow"); fi
echo "==> Localization"
python3 tools/l10n.py check | tail -1
echo "==> Server"
node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$node_major" -ge 22 ]; then
  (cd server && npm ci --silent && npm test)
elif [ -n "${CI:-}" ]; then
  echo "Node.js 22+ is required for the server tests (found: $(node --version 2>/dev/null || echo none))" >&2
  exit 1
else
  echo "skipped: Node.js 22+ not found"
fi
echo "==> Swift"
swift test
