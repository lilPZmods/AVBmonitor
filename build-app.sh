#!/bin/zsh
# Builds "AVB Manager.app" (menu-bar app), installs it in /Applications and starts it at login.
set -e
cd "$(dirname "$0")"
APP="/Applications/AVB Manager.app"
OLD="$HOME/Applications/AVB Manager.app"   # earlier versions installed here
LABEL=ca.arraymusic.avbmanager-app
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x "AVB Manager" 2>/dev/null || true
rm -rf "$OLD"
if [[ "$1" == "uninstall" ]]; then rm -rf "$APP" "$PLIST"; echo "AVB Manager app removed"; exit 0; fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library App/*.swift -o "$APP/Contents/MacOS/AVB Manager"
cp /System/Library/Sounds/Basso.aiff "$APP/Contents/Resources/" 2>/dev/null || true   # alert sound

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AVB Manager</string>
  <key>CFBundleDisplayName</key><string>AVB Manager</string>
  <key>CFBundleIdentifier</key><string>ca.arraymusic.avbmanager</string>
  <key>CFBundleExecutable</key><string>AVB Manager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "AVB Manager installed in /Applications and running (look for the icon in the menu bar)."
