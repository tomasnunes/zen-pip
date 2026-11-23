#!/bin/bash
# Builds ZenPiP, copies it to ~/Applications, and starts it now and at every login.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh

APP="$HOME/Applications/ZenPiP.app"
PLIST="$HOME/Library/LaunchAgents/local.zenpip.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/local.zenpip" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$APP"
cp -R build/ZenPiP.app "$APP"
template=$(<Resources/LaunchAgent.plist)
printf '%s\n' "${template//__HOME__/$HOME}" > "$PLIST"

# Starting it again straight after stopping it can fail for a moment, so try a few times.
for attempt in 1 2 3 4 5; do
  if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then break; fi
  if [ "$attempt" = 5 ]; then launchctl bootstrap "$DOMAIN" "$PLIST"; fi  # show the error
  sleep 1
done

cat <<'MSG'

ZenPiP is installed and running.

Next, give it Accessibility permission. macOS may show a prompt; click Open System Settings.
In Privacy & Security > Accessibility, switch ZenPiP on. If it isn't listed, click + and choose
~/Applications/ZenPiP.app (press Cmd-Shift-G and type ~/Applications).
MSG
signature=$(codesign -dvv "$APP" 2>&1 || true)
if [[ $signature == *"Authority=ZenPiP Local Signing"* ]]; then
  cat <<'MSG'

Signed with your ZenPiP Local Signing certificate, so updates keep the permission. Only the first
build signed this way needs the old ZenPiP entry removed with minus (-) and added again with plus (+).
MSG
else
  cat <<'MSG'

Updating from an earlier build? Remove the old ZenPiP entry with the minus (-) button first,
then add it again with plus (+). macOS ties the permission to each exact build, so switching
the old entry off and on is not enough. To skip this on future updates, see "Keep the permission
across updates" in README.md.
MSG
fi
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
