#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/M4B Converter.app"
CONFIG="${1:-release}"

# Overridable from the environment:
#   BUNDLE_ID      bundle identifier (default io.github.greenglasst.m4bconverter)
#   VERSION        CFBundleShortVersionString (default 1.0)
#   BUILD_NUMBER   CFBundleVersion (default 1)
#   SIGN_IDENTITY  codesign identity. Default "-" signs ad hoc, which runs on the
#                  machine that built it. A "Developer ID Application" identity (name
#                  or SHA-1) also turns on the hardened runtime and a secure
#                  timestamp, which notarization requires.
BUNDLE_ID="${BUNDLE_ID:-io.github.greenglasst.m4bconverter}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

# Drawn from source every build rather than committed as a binary, so the icon stays
# reviewable as a diff. Two seconds, and it keeps the .icns out of git.
echo "Drawing icon…"
swift "$ROOT/Scripts/make-icon.swift" >/dev/null
iconutil -c icns "$ROOT/Scripts/AppIcon.iconset" -o "$ROOT/Scripts/AppIcon.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/M4BConverter" "$APP/Contents/MacOS/M4BConverter"
cp "$ROOT/Scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>M4BConverter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>M4B Converter</string>
  <key>CFBundleDisplayName</key><string>M4B Converter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built: $APP"
