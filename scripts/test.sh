#!/bin/bash
# Builds ZenPiP and runs its self-test (movement maths and window rules; touches no windows).
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh >/dev/null
build/ZenPiP.app/Contents/MacOS/ZenPiP --selftest
