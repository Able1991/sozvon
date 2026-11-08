#!/bin/zsh
# End-to-end check of updates (Sparkle) on a built build/Sozvon.app, with no GitHub and no real keys:
# version A (9.0.0) and version B (9.0.1) are made from the same build, signed ad-hoc, with a throwaway
# EdDSA key; B goes into a DMG and a local appcast served on 127.0.0.1. A is started with its own bundle id
# and data folders, Sparkle finds B, downloads and verifies it, we quit A and Sparkle installs B in its place.
# Passes when A's bundle on disk is now 9.0.1. Used by CI after ./build.sh; runs locally too (a window opens).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d build/Sozvon.app ] || { echo "build/Sozvon.app is missing: run ./build.sh first" >&2; exit 1; }
SPARKLE=.build/artifacts/sparkle/Sparkle/bin
ID=io.github.able1991.sozvon.updtest
PORT=8765
T=$(mktemp -d /tmp/sozvon-update.XXXXXX)
mkdir -p "$T/A" "$T/B" "$T/www" "$T/data/engine" "$T/data/calls" "$T/data/logs"

# Throwaway key pair: the private key never leaves the temp folder.
cat > "$T/genkey.swift" <<'EOF'
import CryptoKit
import Foundation
let k = Curve25519.Signing.PrivateKey()
try! k.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(k.publicKey.rawRepresentation.base64EncodedString())
EOF
PUB=$(swift "$T/genkey.swift" "$T/ed.key")

make() {  # $1 version, $2 folder
  ditto build/Sozvon.app "$2/Sozvon.app"
  local p="$2/Sozvon.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $ID" -c "Set CFBundleShortVersionString $1" \
    -c "Set CFBundleVersion $1" -c "Set SUFeedURL http://127.0.0.1:$PORT/appcast.xml" -c "Set SUPublicEDKey $PUB" "$p"
  codesign --force --deep -s - "$2/Sozvon.app"
}
make 9.0.0 "$T/A"
make 9.0.1 "$T/B"
hdiutil create -quiet -volname Sozvon -srcfolder "$T/B" -format UDZO "$T/www/Sozvon-9.0.1.dmg"
SIG=$("$SPARKLE/sign_update" --ed-key-file "$T/ed.key" -p "$T/www/Sozvon-9.0.1.dmg")
LEN=$(stat -f %z "$T/www/Sozvon-9.0.1.dmg")
cat > "$T/www/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Sozvon</title>
<item><title>Sozvon 9.0.1</title><sparkle:version>9.0.1</sparkle:version><sparkle:shortVersionString>9.0.1</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
<enclosure url="http://127.0.0.1:$PORT/Sozvon-9.0.1.dmg" length="$LEN" type="application/octet-stream" sparkle:edSignature="$SIG"/></item>
</channel></rss>
EOF

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" >"$T/http.log" 2>&1 &
HTTP=$!
cleanup() {
  kill $HTTP 2>/dev/null || true
  osascript -e "tell application id \"$ID\" to quit" >/dev/null 2>&1 || true
  pkill -f "$T/A/Sozvon.app" 2>/dev/null || true
  defaults delete "$ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The test copy's own data folders; set up; the last check long ago, so Sparkle checks right at launch.
defaults delete "$ID" >/dev/null 2>&1 || true
defaults write "$ID" engineDir "$T/data/engine"
defaults write "$ID" callsDir "$T/data/calls"
defaults write "$ID" logsDir "$T/data/logs"
defaults write "$ID" setupDone -bool true
defaults write "$ID" SULastCheckTime -date "2020-01-01 00:00:00 +0000"
defaults write "$ID" SUHasLaunchedBefore -bool true

open -n "$T/A/Sozvon.app"
echo "Waiting for Sparkle to download the update…"
for i in {1..90}; do
  grep -q "GET /Sozvon-9.0.1.dmg" "$T/http.log" 2>/dev/null && break
  sleep 2
done
grep -q "GET /appcast.xml" "$T/http.log" || { echo "FAIL: the appcast was never requested" >&2; cat "$T/http.log"; exit 1; }
grep -q "GET /Sozvon-9.0.1.dmg" "$T/http.log" || { echo "FAIL: the update was never downloaded" >&2; cat "$T/http.log"; exit 1; }
# Downloaded: give Sparkle time to verify and unpack, then quit (or it already restarted in a quiet moment).
sleep 20
osascript -e "tell application id \"$ID\" to quit" >/dev/null 2>&1 || true
for i in {1..60}; do
  v=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$T/A/Sozvon.app/Contents/Info.plist" 2>/dev/null || true)
  [ "$v" = 9.0.1 ] && break
  sleep 2
done
echo "Installed version: ${v:-none}"
[ "$v" = 9.0.1 ] || { echo "FAIL: the update was not installed" >&2; ls -la "$T/A"; exit 1; }
codesign --verify --deep --strict "$T/A/Sozvon.app"
echo "OK: 9.0.0 updated itself to 9.0.1"
