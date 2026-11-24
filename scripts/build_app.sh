#!/bin/bash
# Builds "Strata Music.app" (a universal binary), signs it ad hoc, and packs a .dmg and a .zip into dist/.
set -euo pipefail
VERSION="${1:?usage: build_app.sh VERSION}"
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/StrataMusic"

rm -rf dist build; mkdir -p dist build
APP="dist/Strata Music.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StrataMusic"

# the app icon: the same picture as the Android app (assets/AppIcon.png, 1024 px)
ICONSET=build/AppIcon.iconset; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Strata Music</string>
  <key>CFBundleDisplayName</key><string>Strata Music</string>
  <key>CFBundleIdentifier</key><string>com.auraos.music.mac</string>
  <key>CFBundleExecutable</key><string>StrataMusic</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Strata Music</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Audio</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.audio</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# signing: with a Developer ID certificate (SIGN_ID) the app is signed for real and notarized, so macOS never warns;
# without one it is signed ad hoc and the first launch needs right-click > Open
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose "$APP"

( cd dist && ditto -c -k --keepParent "Strata Music.app" "Strata-Music-${VERSION}-mac.zip" )

# the installer window
NOTE=1; [ -n "${SIGN_ID:-}" ] && NOTE=0
swift scripts/make_dmg_background.swift build/bg.png 1 $NOTE
swift scripts/make_dmg_background.swift build/bg@2x.png 2 $NOTE
tiffutil -cathidpicheck build/bg.png build/bg@2x.png -out build/dmg-bg.tiff
python3 -m venv build/venv && build/venv/bin/pip install --quiet dmgbuild
DMG="dist/Strata-Music-${VERSION}.dmg"
build/venv/bin/dmgbuild -s scripts/dmg_settings.py -D app="$APP" -D volicon=build/AppIcon.icns -D bg=build/dmg-bg.tiff "Strata Music" "$DMG"

if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  if [ -n "${APPLE_ID:-}" ]; then
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
  fi
fi
ls -la dist
