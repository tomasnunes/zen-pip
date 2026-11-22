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
# Signed "ad hoc" (no developer certificate needed). macOS ties the Accessibility permission to
# this exact signature, which is why a rebuilt app needs the permission granted again.
codesign --force --sign - --identifier local.zenpip "$APP"
echo "Built $APP"
