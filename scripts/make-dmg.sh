#!/usr/bin/env bash
# Build a DMG from build/export/anmolAudio.app. Writes:
#   build/anmolAudio.dmg           — stable name, what the landing page links to
#   build/anmolAudio-$VERSION}.dmg  — versioned, what Sparkle appcast enclosures point at
#
# Requires: brew install create-dmg
set -euo pipefail

cd "$(dirname "$0")/.."

APP=build/export/anmolAudio.app
if [[ ! -d "$APP" ]]; then
    echo "Missing $APP. Run scripts/build-release.sh first." >&2
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg not found. Install with: brew install create-dmg" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

rm -f build/anmolAudio.dmg "build/anmolAudio-${VERSION}.dmg"

echo "==> creating DMG (version $VERSION)"
create-dmg \
    --volname "anmolAudio $VERSION" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "anmolAudio.app" 140 180 \
    --app-drop-link 400 180 \
    --no-internet-enable \
    "build/anmolAudio.dmg" \
    "$APP"

cp "build/anmolAudio.dmg" "build/anmolAudio-${VERSION}.dmg"

echo "==> wrote build/anmolAudio.dmg and build/anmolAudio-${VERSION}.dmg"
