#!/usr/bin/env bash
# Regenerates the icon from its source. Tools/IconRenderer.swift is the single authority:
# no .icns is committed, so the app and the README image can never drift apart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET="$ROOT/Resources/AppIcon.iconset"

echo "==> rendering icon"
rm -rf "$ICONSET"
swift "$ROOT/Tools/IconRenderer.swift" "$ICONSET"

echo "==> building AppIcon.icns"
rm -f "$ROOT/Resources/AppIcon.icns"
iconutil --convert icns --output "$ROOT/Resources/AppIcon.icns" "$ICONSET"

mkdir -p "$ROOT/docs"
cp "$ICONSET/icon_512x512@2x.png" "$ROOT/docs/icon.png"
echo "    Resources/AppIcon.icns, docs/icon.png"
