#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# The one place the version is written. It used to be typed into the plist below,
# which is how the app came to report 0.1.0 while the repo was tagged v0.2.0.
VERSION="$(tr -d '[:space:]' < VERSION)"
# Build number has to increase monotonically for macOS, and commit count does that
# for free. Homebrew builds from a tarball with no .git, hence the fallback.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c release
BIN=".build/release/Cbar"
APP="Cbar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cbar"

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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

echo "built $APP ($VERSION build $BUILD)"
