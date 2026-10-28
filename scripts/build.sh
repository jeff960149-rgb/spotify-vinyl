#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${VINYL_OUTPUT_DIR:-$ROOT/build}"
ARCH="${VINYL_ARCH:-$(uname -m)}"
SDK="${VINYL_SDK:-$(xcrun --show-sdk-path)}"
case "$ARCH" in arm64|x86_64) ;; *) print -u2 "Unsupported architecture: $ARCH"; exit 1 ;; esac
STAGING="$(mktemp -d -t vinyl-build)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Vinyl.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUTPUT"
xcrun swiftc -sdk "$SDK" -target "$ARCH-apple-macosx14.0" \
  "$ROOT/Source/main.swift" -o "$APP/Contents/MacOS/Vinyl" -O \
  -framework AppKit -framework QuartzCore -framework ApplicationServices
cp "$ROOT/Source/Info.plist" "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
# Package before copying to cloud-synced folders, which may add Finder metadata.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUTPUT/Vinyl-macOS-$ARCH.zip"
ditto --norsrc --noextattr "$APP" "$OUTPUT/Vinyl.app"
(cd "$OUTPUT" && shasum -a 256 "Vinyl-macOS-$ARCH.zip" > "Vinyl-macOS-$ARCH.sha256")
print "Built: $OUTPUT/Vinyl.app"
print "Release: $OUTPUT/Vinyl-macOS-$ARCH.zip"
