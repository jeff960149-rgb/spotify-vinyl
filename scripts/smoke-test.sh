#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${VINYL_OUTPUT_DIR:-$ROOT/build}"
PREVIEWS="${VINYL_PREVIEW_DIR:-$OUTPUT/previews}"
mkdir -p "$PREVIEWS"
VINYL_PREVIEW_DIR="$PREVIEWS" "$OUTPUT/Vinyl.app/Contents/MacOS/Vinyl" --preview
[[ -s "$PREVIEWS/vinyl-idle.png" && -s "$PREVIEWS/vinyl-hover.png" ]]
print "PASS: preview image files exist"
