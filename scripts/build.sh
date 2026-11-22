#!/bin/bash
# Builds build/ZenPiP.app from Sources/ZenPiP. Needs the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools first: xcode-select --install" >&2
  exit 1
fi

APP=build/ZenPiP.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Built for macOS 13 or later, for this Mac's processor (Apple silicon or Intel).
xcrun swiftc -O -swift-version 5 -module-name ZenPiP -target "$(uname -m)-apple-macos13" \
  -framework AppKit -framework ApplicationServices -framework QuartzCore -framework CoreAudio \
  -o "$APP/Contents/MacOS/ZenPiP" Sources/ZenPiP/*.swift
# macOS ties the Accessibility permission to the app's signature. Signed with your own
# "ZenPiP Local Signing" certificate (see README.md, "Keep the permission across updates"), every
# build keeps the permission. Without one it's signed "ad hoc" (no certificate needed), which ties
# the permission to this exact build, so a rebuilt app needs it granted again.
IDENTITY="ZenPiP Local Signing"
identities=$(security find-identity -p codesigning 2>/dev/null || true)
[[ $identities == *"\"$IDENTITY\""* ]] || IDENTITY="-"
codesign --force --sign "$IDENTITY" --identifier local.zenpip "$APP"
echo "Built $APP"
