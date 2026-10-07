#!/bin/bash
# Builds a universal Conductor.app signed with the Developer ID certificate in the keychain,
# notarizes it when a notarytool keychain profile exists, staples the ticket, and zips it to
# dist/Conductor-<version>.zip for a GitHub release. Doesn't touch /Applications.
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

shasum -a 256 "$ZIP"
