#!/bin/zsh
# Builds Split.app (menu-bar app + CLI in one binary) with the Swift toolchain.
set -euo pipefail
cd "${0:A:h}"

APP=build/Split.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# A universal binary, so the same app runs natively on Apple silicon and on Intel Macs.
# ARCHS="arm64" ./build.sh builds a single slice (quicker while developing).
archs=(${=ARCHS:-arm64 x86_64})
slices=()
for arch in $archs; do
  swiftc -O -target "$arch-apple-macos13.0" \
    -sdk "$(xcrun --show-sdk-path)" \
    -module-name Split \
    Sources/**/*.swift \
    -o "build/Split-$arch" &
  slices+=("build/Split-$arch")
done
wait
for slice in $slices; do [[ -x $slice ]] || { echo "✗ build failed ($slice)" >&2; exit 1; }; done
lipo -create $slices -output "$APP/Contents/MacOS/Split"
rm -f $slices

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.split</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>pt</string><string>fr</string><string>es</string></array>
  <key>CFBundleName</key><string>Split</string>
  <key>CFBundleDisplayName</key><string>Split</string>
  <key>CFBundleExecutable</key><string>Split</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>Split uses Pages, Numbers, Keynote and Microsoft Office to convert files in their formats.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.item</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [[ ! -f Resources/AppIcon.icns ]]; then
  mkdir -p build
  swiftc -O Resources/Icon/main.swift Sources/Interface/Logo.swift -o build/make-icon
  build/make-icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Interface text (English is built in; the tables translate it) and the localized Info.plist.
cp -R Resources/Localization "$APP/Contents/Resources/Localization"
for lproj in Resources/Localization/*.lproj(N); do
  if [[ -f $lproj/InfoPlist.strings ]]; then
    mkdir -p "$APP/Contents/Resources/${lproj:t}"
    cp "$lproj/InfoPlist.strings" "$APP/Contents/Resources/${lproj:t}/"
  fi
done

codesign --force --sign - "$APP" >/dev/null
echo "✓ $APP"
