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

# icon (not fatal if it can't be drawn)
if swift scripts/make_icon.swift "$PWD/build/AppIcon.iconset" && iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"; then
  echo "icon ok"
else
  echo "warning: no icon"
fi

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

codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

( cd dist && ditto -c -k --keepParent "Strata Music.app" "Strata-Music-${VERSION}-mac.zip" )
mkdir -p build/dmg && cp -R "$APP" build/dmg/ && ln -sf /Applications build/dmg/Applications
hdiutil create -volname "Strata Music" -srcfolder build/dmg -ov -format UDZO "dist/Strata-Music-${VERSION}.dmg"
ls -la dist
