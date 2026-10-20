#!/bin/bash
# Builds Alarm.app. No Xcode project, no package manifest — swiftc plus a bundle.
#
# Signing with a stable Developer ID identity matters here: the Accessibility
# grant is tied to the app's code signature, so an ad-hoc signature would mean
# re-granting permission after every single build.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Alarm"
BUILD_DIR="build"
BUNDLE="$BUILD_DIR/$APP_NAME.app"
MIN_MACOS="14.0"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Rafael Cury Rayes (N7Z47ZX3FQ)}"

# --- icon (cached; delete Resources/AppIcon.icns to redraw) -------------------
if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "Drawing app icon..."
    ICONSET="$(mktemp -d)/$APP_NAME.iconset"
    swift Tools/MakeIcon.swift "$ICONSET"
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

# --- compile -----------------------------------------------------------------
echo "Compiling..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc -O -parse-as-library \
    -target "$(uname -m)-apple-macos$MIN_MACOS" \
    -o "$BUNDLE/Contents/MacOS/$APP_NAME" \
    Sources/*.swift

# --- assemble ----------------------------------------------------------------
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# --- sign --------------------------------------------------------------------
echo "Signing as: $IDENTITY"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$BUNDLE"
codesign --verify --strict "$BUNDLE"

echo "Built $BUNDLE"
