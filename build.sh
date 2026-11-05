#!/bin/bash
# Сборка Sozvon.app (и по желанию DMG) из пакета SwiftPM.
#   ./build.sh            собрать build/Sozvon.app
#   ./build.sh install    собрать и положить в ~/Applications
#   ./build.sh dmg        собрать build/Sozvon.dmg (с NOTARY_PROFILE: нотаризовать .app, потом DMG)
#   ./build.sh preview    сборка для скриншотов: --preview <экран> (флаг SOZVON_PREVIEW)
#
# Подпись: SIGN_ID (по умолчанию первый «Developer ID Application» в связке ключей,
# иначе локальный «Sozvon Local Signing», иначе ad-hoc).
# Нотаризация: один раз
#   xcrun notarytool store-credentials sozvon --apple-id <id> --team-id <team> --password <app-specific>
# потом NOTARY_PROFILE=sozvon ./build.sh dmg
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
OUT=build
APP="$OUT/Sozvon.app"
RES="$APP/Contents/Resources"
SRC=Sources/Sozvon

echo "==> Компилирую"
SWIFT_FLAGS=(-c release --arch arm64)
if [ "$MODE" = "preview" ]; then SWIFT_FLAGS+=(-Xswiftc -DSOZVON_PREVIEW); fi
swift build "${SWIFT_FLAGS[@]}"
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES/engine"
cp "$BIN/Sozvon" "$APP/Contents/MacOS/Sozvon"

echo "==> Кладу движок"
# Всё дерево движка, кроме тестов и локального окружения разработчика.
rsync -a --delete \
  --exclude 'tests/' --exclude '.venv/' --exclude '__pycache__/' --exclude '*.pyc' --exclude '.pytest_cache/' \
  --exclude '.DS_Store' --exclude 'ENGINE_VERSION' --exclude 'pyannote-models-v1.tar.gz' \
  engine/ "$RES/engine/"
# Версия движка: первые 16 hex sha256 от содержимого всех скопированных файлов по порядку путей.
# По ней приложение понимает, что код в папке данных надо обновить.
( cd "$RES/engine" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 cat | shasum -a 256 | cut -c1-16 ) \
  > "$RES/engine/ENGINE_VERSION"
# Без этого движок в папке данных не запустится (контракт, раздел 3).
for f in server.py setup.sh models.json pyproject.toml uv.lock vocab.default.json bin/process_call.py bin/discover_projects.py; do
  [ -e "$RES/engine/$f" ] || { echo "ОШИБКА: в бандле нет engine/$f" >&2; exit 1; }
done

# Модели разбивки по голосам внутри приложения (29 МБ): установка не зависит от сети GitHub.
if [ ! -f build/pyannote-models-v1.tar.gz ]; then
  curl -fsSL -o build/pyannote-models-v1.tar.gz \
    https://github.com/Able1991/sozvon/releases/download/models-v1/pyannote-models-v1.tar.gz \
    || echo "ВНИМАНИЕ: нет build/pyannote-models-v1.tar.gz, установка будет качать его из релиза"
fi
if [ -f build/pyannote-models-v1.tar.gz ]; then
  cp build/pyannote-models-v1.tar.gz "$RES/engine/"
elif [ -n "${CI:-}" ]; then
  echo "ОШИБКА: в CI нет архива моделей pyannote (релиз models-v1)" >&2; exit 1
fi

if [ -f "$SRC/Resources/AppIcon.icns" ]; then cp "$SRC/Resources/AppIcon.icns" "$RES/"; fi
cp -R "$SRC"/Resources/*.lproj "$RES/"
python3 tools/l10n.py check >/dev/null || { python3 tools/l10n.py check; echo "ОШИБКА: строки без перевода" >&2; exit 1; }

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleLocalizations</key><array><string>ru</string><string>en</string></array>
  <key>CFBundleIdentifier</key><string>io.github.able1991.sozvon</string>
  <key>CFBundleName</key><string>Sozvon</string>
  <key>CFBundleDisplayName</key><string>Sozvon</string>
  <key>CFBundleExecutable</key><string>Sozvon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSMicrophoneUsageDescription</key><string>Sozvon записывает твой голос во время звонка для локальной расшифровки.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Sozvon записывает звук собеседников во время звонка. Видео не записывается.</string>
</dict></plist>
PLIST

if [ -z "${SIGN_ID:-}" ]; then
  IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
  SIGN_ID=$(echo "$IDS" | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)
  if [ -z "$SIGN_ID" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"Sozvon Local Signing"'; then
    SIGN_ID="Sozvon Local Signing"
  fi
  SIGN_ID="${SIGN_ID:--}"
fi
echo "==> Подписываю: $SIGN_ID"
ENTITLEMENTS="$SRC/Sozvon.entitlements"
if [[ "$SIGN_ID" == Developer\ ID* ]]; then
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
else
  codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
fi
echo "Собрано: $APP ($VERSION, сборка $BUILD)"

case "$MODE" in
  install)
    rm -rf "$HOME/Applications/Sozvon.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Установлено: ~/Applications/Sozvon.app"
    ;;
  dmg)
    # Порядок: .app нотаризуется и степлится до упаковки (тикет внутри .app работает и без сети
    # после копирования из DMG), затем DMG подписывается, нотаризуется и степлится сам.
    if [ -n "${NOTARY_PROFILE:-}" ] && [[ "$SIGN_ID" != Developer\ ID* ]]; then
      echo "ОШИБКА: NOTARY_PROFILE задан, но подпись не Developer ID ($SIGN_ID)" >&2; exit 1
    fi
    notarize() {  # $1: файл для notarytool (zip или dmg); ошибка, если Apple не приняла
      local out
      out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 2h 2>&1) || { echo "$out" >&2; return 1; }
      echo "$out"
      grep -q "status: Accepted" <<<"$out" || { echo "ОШИБКА: нотаризация $1 не принята" >&2; return 1; }
    }
    if [ -n "${NOTARY_PROFILE:-}" ]; then
      echo "==> Нотаризация приложения"
      ZIP="$OUT/Sozvon-notarize.zip"
      rm -f "$ZIP"
      ditto -c -k --keepParent "$APP" "$ZIP"
      notarize "$ZIP"
      rm -f "$ZIP"
      xcrun stapler staple "$APP"
    fi
    echo "==> Собираю DMG"
    STAGE="$OUT/dmg"
    rm -rf "$STAGE" "$OUT/Sozvon.dmg"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/Sozvon.app"  # ditto сохраняет подпись, тикет и атрибуты
    ln -s /Applications "$STAGE/Applications"
    # На машинах CI hdiutil иногда отвечает «Resource busy» (файлы держит XProtect): повторяем.
    for i in 1 2 3 4 5; do
      hdiutil create -volname Sozvon -srcfolder "$STAGE" -ov -format UDZO "$OUT/Sozvon.dmg" >/dev/null && break
      [ "$i" = 5 ] && { echo "ОШИБКА: hdiutil не создал DMG" >&2; exit 1; }
      echo "hdiutil занят, попытка $((i + 1)) через $((i * 5)) с"; sleep $((i * 5))
    done
    rm -rf "$STAGE"
    if [[ "$SIGN_ID" == Developer\ ID* ]]; then codesign --sign "$SIGN_ID" --timestamp "$OUT/Sozvon.dmg"; fi
    if [ -n "${NOTARY_PROFILE:-}" ]; then
      echo "==> Нотаризация DMG"
      notarize "$OUT/Sozvon.dmg"
      xcrun stapler staple "$OUT/Sozvon.dmg"
    fi
    echo "DMG: $OUT/Sozvon.dmg"
    ;;
esac
