#!/bin/bash
# Builds a universal Conductor.app signed with the Developer ID certificate in the keychain,
# notarizes it when a notarytool keychain profile exists, staples the ticket, zips it to
# dist/Conductor-<version>.zip, and writes the Sparkle appcast for it to dist/appcast.xml. Both
# go on the GitHub release; the app checks the latest release's appcast. The appcast is signed
# with the Sparkle EdDSA key in the keychain (its public half is in build-app.sh). Doesn't
# touch /Applications. Gesture log uploads stay off unless CONDUCTOR_UPLOAD_URL and
# CONDUCTOR_UPLOAD_TOKEN are set in the environment, the same as build-app.sh.
#
#   VERSION=0.1.0 BUILD_NUMBER=1 scripts/release.sh
#
# Store the notarization profile once (it asks for an app-specific password):
#   xcrun notarytool store-credentials conductor-notary --apple-id <apple id> --team-id <team id>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?set VERSION, e.g. VERSION=0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-conductor-notary}"
IDENTITY="${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
if [[ -z "$IDENTITY" ]]; then
  echo "error: no Developer ID Application identity in the keychain" >&2
  exit 1
fi

DIST=dist
rm -rf "$DIST"
mkdir -p "$DIST"
ARCHS="arm64 x86_64" VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" CODE_SIGN_IDENTITY="$IDENTITY" \
  APP_OUTPUT="$DIST/Conductor.app" ./build-app.sh

ZIP="$DIST/Conductor-$VERSION.zip"
zip_app() { rm -f "$ZIP"; ditto -c -k --keepParent "$DIST/Conductor.app" "$ZIP"; }
zip_app

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  result="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  echo "$result"
  if ! grep -q 'status: Accepted' <<<"$result"; then
    echo "error: notarization did not pass; see xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  fi
  xcrun stapler staple "$DIST/Conductor.app"
  zip_app
  spctl -a -vv -t exec "$DIST/Conductor.app"
else
  echo "warning: not notarized; no notarytool keychain profile named '$NOTARY_PROFILE'." >&2
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id <team id>" >&2
fi

# The appcast entry signs the final zip, so this comes after stapling.
GENERATE_APPCAST="$(find .build/artifacts -type f -name generate_appcast -print -quit)"
if [[ -z "$GENERATE_APPCAST" ]]; then
  echo "error: generate_appcast not found under .build/artifacts" >&2
  exit 1
fi
APPCAST_DIR="$DIST/appcast"
rm -rf "$APPCAST_DIR"
mkdir -p "$APPCAST_DIR"
cp "$ZIP" "$APPCAST_DIR/"
"$GENERATE_APPCAST" \
  --download-url-prefix "https://github.com/dev-talix/conductor/releases/download/v$VERSION/" \
  --link "https://github.com/dev-talix/conductor" \
  "$APPCAST_DIR"
cp "$APPCAST_DIR/appcast.xml" "$DIST/appcast.xml"
rm -rf "$APPCAST_DIR"

# The same zip under a fixed name, so the site's download link
# (releases/latest/download/Conductor.zip) never needs a version in it.
cp "$ZIP" "$DIST/Conductor.zip"

shasum -a 256 "$ZIP"
echo "Upload $ZIP, $DIST/Conductor.zip and $DIST/appcast.xml to the release."
