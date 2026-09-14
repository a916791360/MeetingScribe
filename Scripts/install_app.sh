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

if [[ -e "$INSTALL_PATH" ]]; then
    TRASH_TARGET="$HOME/.Trash/${APP_NAME}-$(date +%Y%m%d-%H%M%S).app"
    mv "$INSTALL_PATH" "$TRASH_TARGET"
fi
ditto "$APP_DIR" "$INSTALL_PATH"
open "$INSTALL_PATH"

# 用 `echo` 而不是 zsh 内置的 `print`：脚本可能被 `bash Scripts/install_app.sh` 调用，
# 那时 `print` 不存在 → 安装动作明明已经做完，却以 127 退出（2026-09-14 踩过）。
echo "Installed: $INSTALL_PATH"
