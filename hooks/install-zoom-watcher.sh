#!/bin/bash
# Installs the Zoom watcher launchd agent.
#
#   ./hooks/install-zoom-watcher.sh              install / upgrade + start
#   ./hooks/install-zoom-watcher.sh --uninstall  stop + remove
#
# Copies (not symlinks) the watcher script out of the repo so a checkout of a
# branch that lacks it can't break the running agent.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.meetingrec.zoom-watcher"
SCRIPT_DEST="$HOME/.local/libexec/meetingrec/zoom-watcher.sh"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DEST="$HOME/.config/meetingrec/zoom-watcher.env"
DOMAIN="gui/$(id -u)"

unload() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
}

if [ "${1:-}" = "--uninstall" ]; then
    unload
    rm -f "$PLIST_DEST" "$SCRIPT_DEST"
    echo "Uninstalled. Config kept at $CONFIG_DEST; remove it manually if unwanted."
    exit 0
fi

mkdir -p "$(dirname "$SCRIPT_DEST")" "$(dirname "$CONFIG_DEST")" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/meetingrec"

install -m 0755 "$HOOKS_DIR/zoom-watcher.sh" "$SCRIPT_DEST"

if [ ! -f "$CONFIG_DEST" ]; then
    install -m 0644 "$HOOKS_DIR/zoom-watcher.env.example" "$CONFIG_DEST"
    echo "Created $CONFIG_DEST — review it (S3 bucket, region, flags) before your next meeting."
fi

sed "s|__HOME__|$HOME|g" "$HOOKS_DIR/$LABEL.plist" > "$PLIST_DEST"
plutil -lint "$PLIST_DEST" >/dev/null

unload   # idempotent reinstall: bootout is a no-op if not loaded
launchctl bootstrap "$DOMAIN" "$PLIST_DEST"

echo "Installed and started $LABEL."
echo "Watcher log: ~/Library/Logs/meetingrec/zoom-watcher.log"
echo "Note: recording only works if the 'meetingrec' binary already has Screen"
echo "Recording (and Microphone) permission — run it once manually to grant."
