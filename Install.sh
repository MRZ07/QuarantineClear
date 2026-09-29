#!/usr/bin/env bash
# Builds and installs QuarantineClear. Never escalates: if /Applications is not writable by
# the current user, it falls back to ~/Applications rather than asking for sudo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="QuarantineClear.app"

"$ROOT/Scripts/build-app.sh"

if [ -w /Applications ]; then
	DEST="/Applications"
else
	DEST="$HOME/Applications"
	echo
	echo "/Applications is not writable by this user; installing to $DEST instead."
	echo "The tool cannot clear quarantine flags inside a directory it cannot write."
	mkdir -p "$DEST"
fi

echo
echo "==> installing to $DEST"
rm -rf "$DEST/$APP_NAME"
cp -R "$ROOT/dist/$APP_NAME" "$DEST/$APP_NAME"
xattr -cr "$DEST/$APP_NAME"
codesign --verify "$DEST/$APP_NAME"
echo "installed: $DEST/$APP_NAME"
echo "open \"$DEST/$APP_NAME\""
