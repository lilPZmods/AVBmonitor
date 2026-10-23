#!/bin/zsh
# One-time setup so the AVB manager's admin-approved recovery can restart the macOS audio engine.
# Adds a sudoers rule that allows exactly one command without a password:  /usr/bin/killall coreaudiod
# Run:  sudo ./setup-recovery.sh          Remove:  sudo ./setup-recovery.sh remove
set -e
[[ $EUID -eq 0 ]] || { echo "Run with sudo:  sudo $0"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
FILE=/etc/sudoers.d/avbwatch

if [[ "$1" == "remove" ]]; then rm -f "$FILE"; echo "Removed $FILE"; exit 0; fi

TMP=$(mktemp)
echo "$USER_NAME ALL=(root) NOPASSWD: /usr/bin/killall coreaudiod" > "$TMP"
visudo -cf "$TMP" >/dev/null            # refuse to install anything that doesn't parse
install -m 0440 -o root -g wheel "$TMP" "$FILE"
rm -f "$TMP"
echo "Done. $USER_NAME can now restart the audio engine from the AVB manager (after admin approval)."
