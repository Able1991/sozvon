#!/bin/bash
# Builds Sozvon.app (and optionally a DMG) from the SwiftPM package.
#   ./build.sh            build build/Sozvon.app
#   ./build.sh install    build and copy to ~/Applications
#   ./build.sh dmg        build build/Sozvon.dmg (with NOTARY_PROFILE: notarize the .app, then the DMG)
#   ./build.sh preview    build for screenshots: --preview <screen> (SOZVON_PREVIEW flag)
#
# Signing: SIGN_ID (defaults to the first "Developer ID Application" in the keychain,
# otherwise the local "Sozvon Local Signing", otherwise ad-hoc).
# Notarization, once:
#   xcrun notarytool store-credentials sozvon --apple-id <id> --team-id <team> --password <app-specific>
# then NOTARY_PROFILE=sozvon ./build.sh dmg
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
OUT=build
APP="$OUT/Sozvon.app"
RES="$APP/Contents/Resources"
SRC=Sources/Sozvon

echo "==> Compiling"
SWIFT_FLAGS=(-c release --arch arm64)
if [ "$MODE" = "preview" ]; then SWIFT_FLAGS+=(-Xswiftc -DSOZVON_PREVIEW); fi
swift build "${SWIFT_FLAGS[@]}"
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$RES/engine"
cp "$BIN/Sozvon" "$APP/Contents/MacOS/Sozvon"
# Sparkle (updates). Sozvon is not sandboxed, so Sparkle's XPC services are not needed (Sparkle's docs).
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

echo "==> Bundling engine"
# The whole engine tree, except tests and the developer's local environment.
rsync -a --delete \
  --exclude 'tests/' --exclude '.venv/' --exclude '__pycache__/' --exclude '*.pyc' --exclude '.pytest_cache/' \
  --exclude '.DS_Store' --exclude 'ENGINE_VERSION' --exclude 'pyannote-models-v1.tar.gz' \
  --exclude 'index.db*' \
  engine/ "$RES/engine/"
# Engine version: first 16 hex chars of sha256 over all copied files' contents, in path order.
# The app uses it to tell that the code in the data folder needs updating.
( cd "$RES/engine" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 cat | shasum -a 256 | cut -c1-16 ) \
  > "$RES/engine/ENGINE_VERSION"
# Without this the engine in the data folder will not start (contract, section 3).
for f in server.py setup.sh models.json pyproject.toml uv.lock vocab.default.json bin/process_call.py bin/discover_projects.py bin/sync_server.py; do
  [ -e "$RES/engine/$f" ] || { echo "ERROR: engine/$f is missing from the bundle" >&2; exit 1; }
done

# Diarization models bundled in the app (29 MB): installation does not depend on reaching GitHub.
if [ ! -f build/pyannote-models-v1.tar.gz ]; then
  curl -fsSL -o build/pyannote-models-v1.tar.gz \
    https://github.com/Able1991/sozvon/releases/download/models-v1/pyannote-models-v1.tar.gz \
    || echo "WARNING: no build/pyannote-models-v1.tar.gz, setup will download it from the release"
fi
if [ -f build/pyannote-models-v1.tar.gz ]; then
  cp build/pyannote-models-v1.tar.gz "$RES/engine/"
elif [ -n "${CI:-}" ]; then
  echo "ERROR: pyannote model archive (release models-v1) is required in CI" >&2; exit 1
fi

echo "==> Bundling server"
# The own-server Worker (server/) as one ES module for "Connect Cloudflare" (Contents/Resources/server):
# worker.js from `wrangler deploy --dry-run` (no Cloudflare account, nothing is deployed) and manifest.json
# with the version and the compatibility settings of server/wrangler.jsonc. Needs Node.js 22 or later;
# without it the app is built anyway and the button says it is unavailable in this build.
bundle_server() {
  if ! command -v node >/dev/null || ! command -v npm >/dev/null; then echo "node or npm not found"; return 1; fi
  local major
  major=$(node -p 'process.versions.node.split(".")[0]')
  if [ "$major" -lt 22 ]; then echo "Node.js $major is too old, 22 or later is needed"; return 1; fi
  (
    cd server
    [ -d node_modules ] || npm ci --no-audit --no-fund --loglevel=error
    rm -rf ../build/worker
    WRANGLER_SEND_METRICS=false npx --no-install wrangler deploy --dry-run --outdir ../build/worker >../build/worker-bundle.log 2>&1 \
      || { cat ../build/worker-bundle.log; exit 1; }
  ) || return 1
  [ -s build/worker/index.js ] || { echo "wrangler produced no build/worker/index.js"; return 1; }
  mkdir -p "$RES/server"
  sed '/^\/\/# sourceMappingURL=/d' build/worker/index.js > "$RES/server/worker.js"
  node -e '
    const fs = require("fs");
    const cfg = JSON.parse(fs.readFileSync("server/wrangler.jsonc", "utf8").replace(/^\s*\/\/.*$/gm, ""));
    const version = /export const VERSION = "([^"]+)"/.exec(fs.readFileSync("server/src/api.ts", "utf8"))[1];
    process.stdout.write(JSON.stringify({ version, main_module: "worker.js", compatibility_date: cfg.compatibility_date,
      compatibility_flags: cfg.compatibility_flags || [] }, null, 2) + "\n");
  ' > "$RES/server/manifest.json"
}
if ! bundle_server; then
  rm -rf "$RES/server"
  if [ -n "${CI:-}" ]; then echo "ERROR: the server bundle is required in CI" >&2; exit 1; fi
  echo "WARNING: server not bundled, \"Connect Cloudflare\" will be unavailable in this build"
fi

if [ -f "$SRC/Resources/AppIcon.icns" ]; then cp "$SRC/Resources/AppIcon.icns" "$RES/"; fi
cp -R "$SRC"/Resources/*.lproj "$RES/"
cp "$SRC"/Resources/*.wav "$RES/"   # recording start and stop sounds
python3 tools/l10n.py check >/dev/null || { python3 tools/l10n.py check; echo "ERROR: untranslated strings" >&2; exit 1; }

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleLocalizations</key><array><string>ru</string><string>en</string></array>
  <key>CFBundleIdentifier</key><string>io.github.able1991.sozvon</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>io.github.able1991.sozvon</string>
    <key>CFBundleURLSchemes</key><array><string>sozvon</string></array>
  </dict></array>
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
  <key>SUFeedURL</key><string>https://github.com/Able1991/sozvon/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>t9fptGwCukFGie88sD0ehLhpPu77G1gmS6AthWQLn84=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSMicrophoneUsageDescription</key><string>Sozvon records your voice during a call to transcribe it locally.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Sozvon records the other participants' audio during a call (FaceTime included) to transcribe it locally.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Sozvon records the other participants' audio during a call. No video is recorded.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Sozvon adds the tasks and notes you pick from a call to Reminders.</string>
  <key>NSRemindersUsageDescription</key><string>Sozvon adds the tasks and notes you pick from a call to Reminders.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Sozvon fills in the call title and participants from the meeting in your calendar.</string>
  <key>NSCalendarsUsageDescription</key><string>Sozvon fills in the call title and participants from the meeting in your calendar.</string>
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
echo "==> Signing: $SIGN_ID"
ENTITLEMENTS="$SRC/Sozvon.entitlements"
if [[ "$SIGN_ID" == Developer\ ID* ]]; then TS=(--timestamp); else TS=(--timestamp=none); fi
# Inside out, no --deep: Sparkle's helpers, the framework, then the app (Sparkle's signing docs).
SPK="$APP/Contents/Frameworks/Sparkle.framework"
for f in "$SPK/Versions/B/Autoupdate" "$SPK/Versions/B/Updater.app" "$SPK"; do
  codesign --force --options runtime "${TS[@]}" --sign "$SIGN_ID" "$f"
done
codesign --force --options runtime "${TS[@]}" --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built: $APP ($VERSION, build $BUILD)"

case "$MODE" in
  install)
    rm -rf "$HOME/Applications/Sozvon.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed: ~/Applications/Sozvon.app"
    ;;
  dmg)
    # Order: the .app is notarized and stapled before packaging (the ticket inside the .app works
    # offline after copying from the DMG), then the DMG itself is signed, notarized and stapled.
    if [ -n "${NOTARY_PROFILE:-}" ] && [[ "$SIGN_ID" != Developer\ ID* ]]; then
      echo "ERROR: NOTARY_PROFILE is set but the identity is not Developer ID ($SIGN_ID)" >&2; exit 1
    fi
    staple() {  # $1: file. Apple's ticket service (CloudKit) sometimes drops the connection: retry.
      local i
      for i in 1 2 3 4 5 6; do
        xcrun stapler staple "$1" && return 0
        echo "stapler failed, retry $((i + 1)) in $((i * 15))s"; sleep $((i * 15))
      done
      return 1
    }
    notarize() {  # $1: file for notarytool (zip or dmg); fails if Apple rejects it
      local out
      out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 2h 2>&1) || { echo "$out" >&2; return 1; }
      echo "$out"
      grep -q "status: Accepted" <<<"$out" || { echo "ERROR: notarization of $1 was not accepted" >&2; return 1; }
    }
    if [ -n "${NOTARY_PROFILE:-}" ]; then
      echo "==> Notarizing app"
      ZIP="$OUT/Sozvon-notarize.zip"
      rm -f "$ZIP"
      ditto -c -k --keepParent "$APP" "$ZIP"
      notarize "$ZIP"
      rm -f "$ZIP"
      staple "$APP"
    fi
    echo "==> Creating DMG"
    STAGE="$OUT/dmg"
    rm -rf "$STAGE" "$OUT/Sozvon.dmg"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/Sozvon.app"  # ditto preserves the signature, ticket and attributes
    # The DMG window (background, icon places, size) comes from packaging/dmg-settings.py. dmgbuild writes
    # it into the image without scripting Finder, so it works on CI too; it lives in its own venv.
    DMGENV="$OUT/dmgbuild-env"
    if [ ! -x "$DMGENV/bin/dmgbuild" ]; then
      python3 -m venv "$DMGENV"
      "$DMGENV/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==1.6.7"
    fi
    # On CI machines hdiutil sometimes says "Resource busy" (XProtect holds the files): retry.
    for i in 1 2 3 4 5; do
      "$DMGENV/bin/dmgbuild" -s packaging/dmg-settings.py -D app="$STAGE/Sozvon.app" \
        -D here="$PWD/packaging" Sozvon "$OUT/Sozvon.dmg" >/dev/null && break
      [ "$i" = 5 ] && { echo "ERROR: dmgbuild failed to create the DMG" >&2; exit 1; }
      echo "dmgbuild failed, retry $((i + 1)) in $((i * 5))s"; sleep $((i * 5))
    done
    rm -rf "$STAGE"
    if [[ "$SIGN_ID" == Developer\ ID* ]]; then codesign --sign "$SIGN_ID" --timestamp "$OUT/Sozvon.dmg"; fi
    if [ -n "${NOTARY_PROFILE:-}" ]; then
      echo "==> Notarizing DMG"
      notarize "$OUT/Sozvon.dmg"
      staple "$OUT/Sozvon.dmg"
    fi
    echo "DMG: $OUT/Sozvon.dmg"
    ;;
esac
