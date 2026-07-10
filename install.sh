#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications/Cbar.app"
mkdir -p "$HOME/Applications"
killall Cbar 2>/dev/null || true
rm -rf "$DEST"
cp -R Cbar.app "$DEST"

PLIST="$HOME/Library/LaunchAgents/com.heymo.cbar.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.heymo.cbar</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/Cbar</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PL

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "installed to $DEST and loaded LaunchAgent (starts at login)"
