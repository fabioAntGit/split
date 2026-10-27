#!/bin/zsh
# Packages Split as a disk image: open it and drag the app onto Applications, along the arrow
# drawn by Resources/DiskImage. Finder lays the window out, so the first time macOS asks to let
# the terminal control Finder.
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

work=$(mktemp -d)
mount=""
trap '[[ -n $mount ]] && hdiutil detach "$mount" -force >/dev/null 2>&1; rm -rf "$work"' EXIT
stage=$work/stage
mkdir -p "$stage/.background"
ditto "$APP" "$stage/Split.app"
ln -s /Applications "$stage/Applications"

# The window's picture, sharp on Retina screens: both sizes in one TIFF.
swiftc -O Resources/DiskImage/main.swift Sources/Interface/Logo.swift -o build/make-dmg-background
build/make-dmg-background "$work/background"
tiffutil -cathidpicheck "$work/background/background.png" "$work/background/background@2x.png" \
  -out "$stage/.background/background.tiff" >/dev/null 2>&1

rm -f "build/$name" "build/$name.sha256"
megabytes=$(( $(du -sm "$stage" | cut -f1) + 20 ))
hdiutil create -volname Split -srcfolder "$stage" -fs HFS+ -format UDRW -size "${megabytes}m" "$work/Split.dmg" >/dev/null
mount=$(hdiutil attach "$work/Split.dmg" -readwrite -noverify -noautoopen | awk -F '\t' '/\/Volumes\// { print $NF }')
volume=${mount:t}

# A window as big as the picture, with no bars; the icons sit on the arrow's ends (see
# Resources/DiskImage). Finder keeps a new size only when it is set again on a reopened window.
osascript <<SCRIPT
tell application "Finder"
  tell disk "$volume"
    open
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      try
        set pathbar visible to false
      end try
      set bounds to {200, 120, 860, 548}
    end tell
    set options to icon view options of container window
    set arrangement of options to not arranged
    set icon size of options to 112
    set text size of options to 13
    set background picture of options to file ".background:background.tiff"
    set position of item "Split.app" of container window to {160, 200}
    set position of item "Applications" of container window to {500, 200}
    close
    open
    delay 1
    tell container window
      set statusbar visible to false
      set bounds to {200, 120, 850, 538}
    end tell
    delay 1
    tell container window
      set statusbar visible to false
      set bounds to {200, 120, 860, 548}
    end tell
    update without registering applications
    delay 2
    close
  end tell
end tell
SCRIPT
sync
hdiutil detach "$mount" >/dev/null
mount=""
hdiutil convert "$work/Split.dmg" -format UDZO -imagekey zlib-level=9 -o "build/$name" >/dev/null

if [[ -n ${SIGN_IDENTITY:-} ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "build/$name"
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    xcrun notarytool submit "build/$name" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "build/$name"
  fi
fi
(cd build && shasum -a 256 "$name" > "$name.sha256")
echo "✓ build/$name ($(lipo -archs "$APP/Contents/MacOS/Split"))"
