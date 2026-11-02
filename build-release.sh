#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

[[ "$(uname -s)" == "Darwin" ]] || { print -u2 "Build the installer on macOS."; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || { print -u2 "This release builder targets Apple silicon Macs."; exit 1; }

VERSION="${1:-1.0}"
[[ "$VERSION" =~ '^[0-9]+([.][0-9]+)*$' ]] || { print -u2 "Version must contain only numbers and dots."; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/payload/Applications/AVB Manager.app"
BIN="$WORK/payload/Library/Application Support/AVBWatch/bin"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BIN" dist

swiftc -O Sources/*.swift -o "$BIN/avbwatch"
swiftc -O avbprobe.swift -o "$BIN/avbprobe"
swiftc -O -parse-as-library App/*.swift -o "$APP/Contents/MacOS/AVB Manager"
cp /System/Library/Sounds/Basso.aiff "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AVB Manager</string>
  <key>CFBundleDisplayName</key><string>AVB Manager</string>
  <key>CFBundleIdentifier</key><string>ca.arraymusic.avbmanager</string>
  <key>CFBundleExecutable</key><string>AVB Manager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
EOF
codesign --force --sign - "$APP" >/dev/null

python3 -m venv "$WORK/venv"
"$WORK/venv/bin/python" -m pip install --quiet --upgrade pip pyinstaller py-ptsl
"$WORK/venv/bin/python" -m PyInstaller --clean --onefile --name pthelper \
  --distpath "$BIN" --workpath "$WORK/pyinstaller-work" --specpath "$WORK" pthelper.py
chmod 755 "$BIN/avbwatch" "$BIN/avbprobe" "$BIN/pthelper"
find "$WORK/payload" -name '._*' -delete
xattr -cr "$WORK/payload"

PACKAGE="$PWD/dist/AVBManager-macos-arm64.pkg"
COPYFILE_DISABLE=1 pkgbuild --root "$WORK/payload" --scripts installer/scripts \
  --identifier ca.arraymusic.avbmanager --version "$VERSION" "$PACKAGE"
print "Created $PACKAGE"