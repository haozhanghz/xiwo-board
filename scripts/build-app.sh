#!/bin/bash
# Builds XiwoBoard.app (录课, arm64) into build/. Run on macOS 15+ with Xcode 16+.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --arch arm64 --product XiwoBoard
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/XiwoBoard"

APP=build/XiwoBoard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XiwoBoard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Shown name: 录课 on Chinese systems, Lesson Recorder elsewhere. The bundle stays XiwoBoard.app
# so in-app updates and granted permissions carry over.
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# App icon from the 1024px master.
if [ -f Resources/AppIcon-1024.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Releases carry the project certificate (SIGN_IDENTITY, see docs/SIGNING.md) so macOS
# keeps screen-recording and microphone permission across updates. Without it the
# app is ad-hoc signed, and an ad-hoc signature changes with every build.
SIGN_ARGS=(--force --sign "${SIGN_IDENTITY:--}")
if [ -n "${SIGN_KEYCHAIN:-}" ]; then SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN"); fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --display --requirements - "$APP" 2>/dev/null | grep 'designated =>' || true
echo "Built $APP"
