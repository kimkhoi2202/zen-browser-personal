#!/bin/bash
# Builds the standalone native chrome harness (no Gecko required).
#   ./build.sh [output]   (default /tmp/ZenPipChromeHarness)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PIP="$HERE/../.."
OUT="${1:-/tmp/ZenPipChromeHarness}"
clang++ -std=c++20 -fobjc-arc -O1 -Wall -Wno-unused-parameter \
  -mmacosx-version-min=11.0 -I"$PIP" \
  "$PIP/ZenPipNativeChrome.mm" "$HERE/ZenPipChromeHarness.mm" \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreText \
  -framework MediaAccessibility -framework QuartzCore \
  -o "$OUT"
echo "$OUT"
