#!/bin/bash
# Builds Conductor.app from the SwiftPM executable.
#
# The .app wrapper is required, not optional: AVFoundation kills any process that touches the
# camera without an NSCameraUsageDescription in its Info.plist, and `swift run` has no plist.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
# Space-separated. "arm64 x86_64" makes a universal binary; a release build does that.
ARCHS="${ARCHS:-$(uname -m)}"
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

OUTPUT_APP="${APP_OUTPUT:-/Applications/Conductor.app}"
# The last build is kept in the repo, not next to the output, so /Applications and Spotlight
# show one Conductor.
PREVIOUS_APP="Conductor.app.previous"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/conductor-build.XXXXXX")"
APP="$STAGING_DIR/Conductor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Conductor" "$APP/Contents/MacOS/Conductor"

if [ ! -f AppIcon.icns ]; then
  swift scripts/make-icon.swift
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Where finished gesture logs go when the user turns on Upload Gesture Logs (see ingest/). Left
# out of the plist, the menu item is greyed out and nothing leaves the Mac.
UPLOAD_PLIST=""
if [[ -n "${CONDUCTOR_UPLOAD_URL:-}" && -n "${CONDUCTOR_UPLOAD_TOKEN:-}" ]]; then
  UPLOAD_PLIST="    <key>ConductorUploadURL</key>
    <string>$CONDUCTOR_UPLOAD_URL</string>
    <key>ConductorUploadToken</key>
    <string>$CONDUCTOR_UPLOAD_TOKEN</string>"
fi

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
    <key>SUFeedURL</key>
    <string>https://github.com/dev-talix/conductor/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>4/wQ6XehB3rZhDeckFB1O5atGbo7TkxxYcDsC175bos=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
$UPLOAD_PLIST
</dict>
</plist>
PLIST

# Sparkle is a binary framework: the build links against it, so the app has to carry it, and the
# binary needs an rpath to find it. Without either the app dies at launch.
SPARKLE_FRAMEWORK="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' -print -quit)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo "error: Sparkle.framework not found under .build/artifacts; run swift package resolve" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/Conductor" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Conductor"
fi

# macOS ties the camera and Accessibility grants to the code signature, and an ad-hoc signature
# changes on every build, which silently voids the grant. Prefer a real identity when one exists.
IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning | grep -q '"Talix Dev Signing"'; then
  IDENTITY="Talix Dev Signing"
fi
SIGN_FLAGS=(--force --sign "${IDENTITY:--}")
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  # Notarization needs the hardened runtime and a secure timestamp, and the hardened runtime
  # needs the camera entitlement before AVFoundation will open the camera. Nested code signs
  # first, inside out: Sparkle carries two XPC services, the Autoupdate helper and Updater.app,
  # and an unsigned one fails notarization.
  while IFS= read -r nested; do
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$nested"
  done < <(find "$APP/Contents/Frameworks/Sparkle.framework" \( -name '*.xpc' -o -name '*.app' -o -name Autoupdate \) -print)
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP/Contents/Frameworks/Sparkle.framework"
  SIGN_FLAGS+=(--options runtime --timestamp --entitlements Conductor.entitlements)
else
  codesign --force --sign "${IDENTITY:--}" --deep "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign "${SIGN_FLAGS[@]}" "$APP"
if [[ "${IDENTITY:--}" == "-" ]]; then
  echo "warning: ad-hoc signed; macOS will forget the Accessibility grant on the next rebuild" >&2
fi
codesign --verify --strict "$APP"

if [[ -e "$OUTPUT_APP" ]]; then
  rm -rf "$PREVIOUS_APP"
  mv "$OUTPUT_APP" "$PREVIOUS_APP"
fi
mv "$APP" "$OUTPUT_APP"
rmdir "$STAGING_DIR"
echo "Built $OUTPUT_APP ($VERSION, build $BUILD_NUMBER, $ARCHS, signed by ${IDENTITY:-ad-hoc}, uploads ${CONDUCTOR_UPLOAD_URL:+to }${CONDUCTOR_UPLOAD_URL:-off})"
