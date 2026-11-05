#!/bin/bash
# Установка движка Sozvon в папку данных (по умолчанию ~/Library/Application Support/Sozvon).
# Запускается приложением при первом старте и из меню «Переустановить движок».
# Можно запускать и руками: engine/setup.sh <папка-данных>
# Повторный запуск безопасен: уже скачанное не качается заново.
# Здесь только окружение Python; модели и метки ставит install.py (его можно тестировать).
set -euo pipefail

DATA="${1:-$HOME/Library/Application Support/Sozvon}"
cd "$DATA"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Сообщения на языке приложения: t "по-русски" "in English".
t() { if [ "${SOZVON_UI_LANG:-ru}" = "ru" ]; then echo "$1"; else echo "$2"; fi; }
step() { echo "==> $*"; }

if [ "$(uname -m)" != "arm64" ]; then
  t "ОШИБКА: нужен Mac на Apple Silicon (M1 и новее), mlx не работает на Intel." "ERROR: Sozvon needs a Mac with Apple silicon (M1 or later); mlx does not run on Intel." >&2
  exit 1
fi

# uv закреплённой версии: готовый бинарник из релиза astral-sh/uv, SHA-256 сверяется
# до распаковки. Скрипт установки (curl | sh) не запускаем. Уже установленный uv берём как есть.
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
uv sync --frozen --no-dev

step "$(t "Подключаю ffmpeg" "Setting up ffmpeg")"
FF=$(.venv/bin/python -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())")
ln -sf "$FF" .venv/bin/ffmpeg

# Модели (models.json, закреплённые ревизии), разбивка по голосам, метки .venv-lock и .installed.
PYTHONWARNINGS=ignore .venv/bin/python install.py "$DATA"
