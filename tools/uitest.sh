#!/bin/zsh
# UI click test over every screen (tools/uitest/UITest.swift). Usage: tools/uitest.sh [screen filter]
# Builds the preview app, copies it with its own bundle id (its settings never touch the real app's) and
# runs it on fresh demo data in a temp folder. Needs Accessibility access for the terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/sozvon-uitest.XXXXXX)
[ "${SKIP_BUILD:-}" = 1 ] || ./build.sh preview >/dev/null
cp -R build/Sozvon.app "$TMP/Sozvon.app"
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier io.github.able1991.sozvon.uitest" "$TMP/Sozvon.app/Contents/Info.plist"
codesign --force --deep -s - "$TMP/Sozvon.app" 2>/dev/null
python3 tools/demo_data.py "$TMP/data" >/dev/null
SHOTS="${UITEST_SHOTS:-$TMP/shots}"
mkdir -p "$SHOTS"
swiftc -O tools/uitest/UITest.swift -o "$TMP/uitest"
defaults delete io.github.able1991.sozvon.uitest >/dev/null 2>&1 || true
"$TMP/uitest" "$TMP/Sozvon.app" "$TMP/data" "$SHOTS" "${1:-}" && rc=0 || rc=$?
echo "Screenshots of failures: $SHOTS"
exit $rc
