#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MeetingScribe"
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME.app"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo >&2 "请先在 MeetingScribe 中结束录音/处理并退出，再运行安装脚本。现有应用未改动。"
    exit 1
fi

"$ROOT_DIR/Scripts/package_app.sh"

# Copy and verify on the destination volume before touching the installed app.
STAGE="$(mktemp -d "$INSTALL_DIR/.MeetingScribe-install.XXXXXX")"
STAGED_APP="$STAGE/$APP_NAME.app"
BACKUP_PATH=""
cleanup() {
    local result=$?
    if [[ $result -ne 0 && -n "$BACKUP_PATH" && ! -e "$INSTALL_PATH" ]]; then
        mv "$BACKUP_PATH" "$INSTALL_PATH" || echo >&2 "恢复失败，原应用保留在：$BACKUP_PATH"
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
ditto "$APP_DIR" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo >&2 "MeetingScribe 已重新运行，安装已停止；请退出后再试。"
    exit 1
fi

if [[ -e "$INSTALL_PATH" ]]; then
    BACKUP_PATH="$INSTALL_DIR/.MeetingScribe-backup-$(date +%Y%m%d-%H%M%S)-$$.app"
    mv "$INSTALL_PATH" "$BACKUP_PATH"
fi
mv "$STAGED_APP" "$INSTALL_PATH"
open "$INSTALL_PATH"

# 用 `echo` 而不是 zsh 内置的 `print`：脚本可能被 `bash Scripts/install_app.sh` 调用，
# 那时 `print` 不存在 → 安装动作明明已经做完，却以 127 退出（2026-09-14 踩过）。
echo "Installed: $INSTALL_PATH"
[[ -z "$BACKUP_PATH" ]] || echo "Previous app retained: $BACKUP_PATH"
