#!/bin/zsh
# Packages Split as a disk image: open it and drag the app onto Applications.
# Usage: ./make-dmg.sh   → build/Split-<version>.dmg (and a .sha256 next to it)
#
# For distribution, sign with a Developer ID certificate and notarize, so the app opens with no warning:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=split ./make-dmg.sh
# (create the profile once with: xcrun notarytool store-credentials split).
# Without them the app keeps its ad hoc signature: it works, but the first time it is opened
# macOS asks for System Settings › Privacy & Security › Open Anyway.
set -euo pipefail
cd "${0:A:h}"

./build.sh
APP=build/Split.app
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
name=Split-$version.dmg

if [[ -n ${SIGN_IDENTITY:-} ]]; then
  codesign --force --options runtime --timestamp --entitlements Resources/Split.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/Split.app"
ln -s /Applications "$stage/Applications"
rm -f "build/$name" "build/$name.sha256"
hdiutil create -volname Split -srcfolder "$stage" -fs HFS+ -format UDZO "build/$name" >/dev/null

if [[ -n ${SIGN_IDENTITY:-} ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "build/$name"
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    xcrun notarytool submit "build/$name" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "build/$name"
  fi
fi
(cd build && shasum -a 256 "$name" > "$name.sha256")
echo "✓ build/$name ($(lipo -archs "$APP/Contents/MacOS/Split"))"
