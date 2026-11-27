#!/usr/bin/env bash
# Assembles a runnable .app bundle from the SwiftPM build and signs it ad-hoc.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

APP="dist/ShortCuts.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/ShortCuts" "$APP/Contents/MacOS/ShortCuts"
cp Resources/Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/ShortCuts"

# Natural-language search model (see scripts/build-semantic-model.py). Without it, search
# still works, but only with word matches.
cp Resources/semantic-model.bin "$APP/Contents/Resources/semantic-model.bin"

# App icon, when present.
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature: enough to run locally. Replace with a Developer ID for distribution.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed; app will still run locally"

echo "Built $APP"
