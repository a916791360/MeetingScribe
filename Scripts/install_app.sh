#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MeetingScribe"
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME.app"

"$ROOT_DIR/Scripts/package_app.sh"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    killall "$APP_NAME" || true
    sleep 1
fi

rm -rf "$INSTALL_PATH"
ditto "$APP_DIR" "$INSTALL_PATH"
open "$INSTALL_PATH"

print "Installed: $INSTALL_PATH"
