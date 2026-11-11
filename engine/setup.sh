#!/bin/bash
# Installs the Sozvon engine into the data folder (default ~/Library/Application Support/Sozvon).
# Run by the app on first launch and from the "Reinstall engine" menu item.
# Can also be run by hand: engine/setup.sh <data-folder>
# Safe to re-run: anything already downloaded is not downloaded again.
# Only the Python environment here; models and markers are installed by install.py (which is testable).
set -euo pipefail

DATA="${1:-$HOME/Library/Application Support/Sozvon}"
cd "$DATA"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Messages in the app language: t "in Russian" "in English".
t() { if [ "${SOZVON_UI_LANG:-ru}" = "ru" ]; then echo "$1"; else echo "$2"; fi; }
step() { echo "==> $*"; }

if [ "$(uname -m)" != "arm64" ]; then
  t "ОШИБКА: нужен Mac на Apple Silicon (M1 и новее), mlx не работает на Intel." "ERROR: Sozvon needs a Mac with Apple silicon (M1 or later); mlx does not run on Intel." >&2
  exit 1
fi

# Corporate networks (docs/CORPORATE.md). Network keys from .env in the data folder, because an
# app opened from Finder does not see the shell environment; the environment wins. Only these keys,
# never the rest of .env (tokens, passwords).
env_key() { [ -f .env ] && sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" .env | tail -1 | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"; }
for KEY in SSL_CERT_FILE REQUESTS_CA_BUNDLE HF_ENDPOINT HTTPS_PROXY HTTP_PROXY NO_PROXY \
           UV_DEFAULT_INDEX PIP_INDEX_URL UV_PYTHON UV_PYTHON_INSTALL_MIRROR; do
  if [ -z "${!KEY:-}" ]; then
    VAL=$(env_key "$KEY" || true)
    if [ -n "$VAL" ]; then export "$KEY=$VAL"; fi
  fi
done
# uv trusts the macOS Keychain, where IT puts the company root certificate (old uv: UV_NATIVE_TLS).
export UV_SYSTEM_CERTS=1 UV_NATIVE_TLS=1
# A package mirror: UV_DEFAULT_INDEX, PIP_INDEX_URL, or index-url from pip.conf.
INDEX="${UV_DEFAULT_INDEX:-${PIP_INDEX_URL:-}}"
if [ -z "$INDEX" ]; then
  for CONF in "$HOME/.config/pip/pip.conf" "$HOME/.pip/pip.conf" "$HOME/Library/Application Support/pip/pip.conf"; do
    if [ -f "$CONF" ]; then
      INDEX=$(sed -n 's/^[[:space:]]*index-url[[:space:]]*=[[:space:]]*//p' "$CONF" | head -1 | sed 's/[[:space:]]*$//')
      if [ -n "$INDEX" ]; then break; fi
    fi
  done
fi

# Pinned uv version: a prebuilt binary from the astral-sh/uv release, SHA-256 verified
# before unpacking. The install script (curl | sh) is not run. An already installed uv is used as is.
UV_VERSION="0.11.26"
UV_SHA256="8f7fbf1708399b921857bce71e1d60f0d3ccf52a30caebc1c1a2f175dce13ab6"
UV_URL="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz"

if ! command -v uv >/dev/null 2>&1; then
  step "$(t "Ставлю uv $UV_VERSION (менеджер Python от astral.sh)" "Installing uv $UV_VERSION (Python manager by astral.sh)")"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL --retry 3 -o "$TMP/uv.tar.gz" "$UV_URL"
  GOT=$(shasum -a 256 "$TMP/uv.tar.gz" | awk '{print $1}')
  if [ "$GOT" != "$UV_SHA256" ]; then
    t "ОШИБКА: контрольная сумма uv не совпала (ждали $UV_SHA256, получили $GOT)." "ERROR: uv checksum mismatch (expected $UV_SHA256, got $GOT)." >&2
    exit 1
  fi
  tar -xzf "$TMP/uv.tar.gz" -C "$TMP"
  mkdir -p "$HOME/.local/bin"
  install -m 755 "$TMP/uv-aarch64-apple-darwin/uv" "$TMP/uv-aarch64-apple-darwin/uvx" "$HOME/.local/bin/"
  rm -rf "$TMP"
  trap - EXIT
fi

step "$(t "Ставлю Python 3.12 и зависимости (около 1 ГБ, только в первый раз)" "Installing Python 3.12 and dependencies (about 1 GB, first time only)")"
if [ -z "$INDEX" ]; then
  uv sync --frozen --no-dev
else
  # The lock points at files.pythonhosted.org, so through a mirror the same pinned versions go
  # in from a requirements file with their SHA-256 hashes: the mirror must serve identical files.
  echo "$(t "Пакеты через зеркало" "Packages through the mirror") $INDEX"
  uv export --frozen --no-dev --no-emit-project --format requirements-txt -o .requirements.txt >/dev/null
  uv venv --allow-existing .venv
  uv pip sync --python .venv/bin/python --index-url "$INDEX" .requirements.txt
fi

step "$(t "Подключаю ffmpeg" "Setting up ffmpeg")"
FF=$(.venv/bin/python -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())")
ln -sf "$FF" .venv/bin/ffmpeg

# Models (models.json, pinned revisions), diarization, .venv-lock and .installed markers.
PYTHONWARNINGS=ignore .venv/bin/python install.py "$DATA"
