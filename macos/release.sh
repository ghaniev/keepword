#!/bin/sh
# Builds a distributable MeetNotes: Developer ID signature + hardened runtime, notarized and stapled DMG in dist/.
# One-time setup:
#   1. Xcode → Settings → Accounts → your team → Manage Certificates → + Developer ID Application
#   2. xcrun notarytool store-credentials meetnotes-notary --apple-id <apple id> --team-id <team id>
#      (password: an app-specific one from account.apple.com)
# Usage: TEAM_ID=<team id> VERSION=0.1.0 BUILD=1 ./release.sh
set -e
cd "$(dirname "$0")"
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team id}"
NOTARY_PROFILE="${NOTARY_PROFILE:-meetnotes-notary}"
VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 | sed -E 's/.*"(.*)"/\1/')}"
[ -n "$SIGN_IDENTITY" ] || { echo "No Developer ID Application certificate for team $TEAM_ID in the keychain" >&2; exit 1; }

SIGN_IDENTITY="$SIGN_IDENTITY" VERSION="$VERSION" ./build_app.sh

DIST=dist && mkdir -p "$DIST"
DMG="$DIST/MeetNotes-$VERSION.dmg"
STAGE="$(mktemp -d)/MeetNotes"
mkdir -p "$STAGE" && cp -R MeetNotes.app "$STAGE/" && ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "MeetNotes $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
echo "Release: $(pwd)/$DMG"
