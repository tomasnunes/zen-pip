#!/bin/bash
# Stops ZenPiP and removes the app, its login item, its settings and its log.
set -uo pipefail
launchctl bootout "gui/$(id -u)/local.zenpip" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.zenpip.plist"
rm -rf "$HOME/Applications/ZenPiP.app"
rm -f "$HOME/Library/Logs/ZenPiP.log"
defaults delete local.zenpip 2>/dev/null
echo "ZenPiP removed. You can also remove its entry in System Settings > Privacy & Security > Accessibility."
