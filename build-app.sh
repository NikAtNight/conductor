#!/bin/bash
# Builds Conductor.app from the SwiftPM executable.
#
# The .app wrapper is required, not optional: AVFoundation kills any process that touches the
# camera without an NSCameraUsageDescription in its Info.plist, and `swift run` has no plist.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCH="$(uname -m)"

swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

OUTPUT_APP="${APP_OUTPUT:-Conductor.app}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/conductor-build.XXXXXX")"
APP="$STAGING_DIR/Conductor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Conductor" "$APP/Contents/MacOS/Conductor"

if [ ! -f AppIcon.icns ]; then
  swift scripts/make-icon.swift
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Conductor</string>
    <key>CFBundleDisplayName</key>
    <string>Conductor</string>
    <key>CFBundleIdentifier</key>
    <string>com.talix.conductor</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>Conductor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSCameraUsageDescription</key>
    <string>Conductor watches your hands through the camera to move the cursor and click. Video never leaves this Mac.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Nikhil Kapadia.</string>
</dict>
</plist>
PLIST

# macOS ties the camera and Accessibility grants to the code signature, and an ad-hoc signature
# changes on every build, which silently voids the grant. Prefer a real identity when one exists.
IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning | grep -q '"Talix Dev Signing"'; then
  IDENTITY="Talix Dev Signing"
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
if [[ "${IDENTITY:--}" == "-" ]]; then
  echo "warning: ad-hoc signed; macOS will forget the Accessibility grant on the next rebuild" >&2
fi
codesign --verify --strict "$APP"

if [[ -e "$OUTPUT_APP" ]]; then
  rm -rf "${OUTPUT_APP}.previous"
  mv "$OUTPUT_APP" "${OUTPUT_APP}.previous"
fi
mv "$APP" "$OUTPUT_APP"
rmdir "$STAGING_DIR"
echo "Built $OUTPUT_APP ($VERSION, build $BUILD_NUMBER)"
