#!/bin/zsh
# Builds the AVB manager and installs it as a LaunchAgent (runs at login, restarts if it exits).
# Re-run after changing the code. Use ./install.sh uninstall to remove.
set -e
cd "$(dirname "$0")"
LABEL=ca.arraymusic.avbwatch
DIR="$HOME/Library/Application Support/AVBWatch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ "$1" == "uninstall" ]]; then
  rm -f "$PLIST"; echo "avbwatch removed (config and log kept in $DIR)"; exit 0
fi

mkdir -p "$DIR"
swiftc -O Sources/*.swift -o avbwatch
swiftc -O avbprobe.swift -o avbprobe
cp avbwatch avbprobe pthelper.py "$DIR/"

# Python environment for talking to Pro Tools (save / session path) during recovery
if [[ ! -x "$DIR/venv/bin/python" ]]; then
  python3 -m venv "$DIR/venv"
  "$DIR/venv/bin/pip" install -q py-ptsl
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DIR/avbwatch</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/AVBWatch.err.log</string>
</dict></plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "AVB manager installed and running. Log: ~/Library/Logs/AVBWatch.log  Web: http://localhost:8077/"
