#!/usr/bin/env bash
# Builds QuarantineClear.app from source.
#
# The package is intentionally NOT sandboxed: the App Sandbox denies the extended-attribute
# writes on /Applications that are this tool's entire purpose.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/QuarantineClear.app"
CONTENTS="$APP/Contents"

echo "==> tests"
swift test --package-path "$ROOT" >/dev/null
echo "    passed"

echo "==> icon"
"$ROOT/Scripts/make-icon.sh"

echo "==> universal release build"
swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64

BINARY=$(swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64 \
	--show-bin-path 2>/dev/null)/QuarantineClear
[ -f "$BINARY" ] || { echo "build did not produce $BINARY" >&2; exit 1; }

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/QuarantineClear"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> ad-hoc signing (not notarised)"
codesign --force --sign - --timestamp=none --options runtime "$APP"

# The tool clears its own flag on its own build output, so a locally built copy launches
# immediately instead of reproducing the exact failure it exists to fix.
echo "==> clearing quarantine on our own build"
xattr -cr "$APP"

echo "==> verifying"
codesign --verify --verbose=2 "$APP"
lipo -archs "$CONTENTS/MacOS/QuarantineClear"
echo
echo "built: $APP"
echo "note:  ad-hoc signed, not notarised. See the README bootstrap section."
