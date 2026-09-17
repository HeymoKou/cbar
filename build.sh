#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# The one place the version is written. It used to be typed into the plist below,
# which is how the app came to report 0.1.0 while the repo was tagged v0.2.0.
VERSION="$(tr -d '[:space:]' < VERSION)"
# Build number has to increase monotonically for macOS, and commit count does that
# for free. Homebrew builds from a tarball with no .git, hence the fallback.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# Extra flags are passed through so the Homebrew formula can build the same
# bundle this script builds: it needs --disable-sandbox, and duplicating the
# build there is how the plist came to carry a hand-typed version.
swift build -c release "$@"
BIN=".build/release/Cbar"
APP="Cbar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cbar"
cp Sources/Cbar/Resources/icon-*.png "$APP/Contents/Resources/"

# Finder / About / Force Quit still show an icon even for an LSUIElement.
# One 1024 PNG is the source; iconutil wants the named .iconset sizes.
ICON_SRC="Sources/Cbar/Resources/AppIcon.png"
ICONSET="$APP/Contents/AppIcon.iconset"
mkdir -p "$ICONSET"
while read -r px name; do
  sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/$name" >/dev/null
done <<SIZES
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cbar</string>
  <key>CFBundleDisplayName</key><string>cbar</string>
  <key>CFBundleIdentifier</key><string>com.heymo.cbar</string>
  <key>CFBundleExecutable</key><string>Cbar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

echo "built $APP ($VERSION build $BUILD)"
