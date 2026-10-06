#!/bin/zsh
# 组装对外分发的 zip —— App + 「首次打开请看这里.txt」，并打印 SHA-256。
#
# 为什么要有这一步（而不是记在文档里让发版的人手敲 ditto）：
#   README 和历次 Release 说明都写着「zip 里附了 首次打开请看这里.txt」，
#   但打包一直是手工敲 ditto 把 .app 包起来的 —— 那个 txt 从来没被带进去过。
#   「文档声明的东西」和「实际做出来的东西」之间靠人记得，就一定会漂。
#   把顺序固定成脚本，声明才作数。
#
# 只用 `echo` 不用 zsh 的 `print`：脚本可能被 `bash Scripts/make_release_zip.sh`
# 调用，那时 `print` 不存在（install_app.sh 2026-09-14 踩过同一个坑）。
#
# 用法：
#   ./Scripts/make_release_zip.sh                      # → ../dist/MeetingScribe-<版本>-macOS.zip
#   ./Scripts/make_release_zip.sh <App路径> <输出目录>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT_DIR/.build/MeetingScribe.app}"
OUT_DIR="${2:-$ROOT_DIR/../dist}"
README_TXT="$ROOT_DIR/Packaging/首次打开请看这里.txt"

if [[ ! -d "$APP" ]]; then
    echo >&2 "找不到应用包：$APP"
    echo >&2 "先跑 ./Scripts/package_app.sh"
    exit 1
fi

if [[ ! -f "$README_TXT" ]]; then
    echo >&2 "找不到随包说明：$README_TXT"
    exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
ZIP="$OUT_DIR/MeetingScribe-${VERSION}-macOS.zip"

mkdir -p "$OUT_DIR"

# 暂存目录：ditto 会连签名和扩展属性一起复制，不能换成 cp -R
STAGE="$(mktemp -d /private/tmp/ms-release-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/MeetingScribe.app"
cp "$README_TXT" "$STAGE/"

# 签名必须随复制活下来 —— 掉了的话包是坏的，而且要到用户那边才发现
if ! codesign --verify --deep --strict "$STAGE/MeetingScribe.app" >/dev/null 2>&1; then
    echo >&2 "✗ 复制后签名校验失败，zip 未生成"
    exit 1
fi

# 扫的就是最终要发出去的那一份（package_app.sh 验的是 .build 里的，不是这里）
"$ROOT_DIR/Scripts/audit_release.sh" "$STAGE/MeetingScribe.app"

# Local self-signed builds remain supported. Public notarized releases opt into this gate.
if [[ "${REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
    xcrun stapler validate "$STAGE/MeetingScribe.app"
    spctl --assess --type execute "$STAGE/MeetingScribe.app"
fi

rm -f "$ZIP"
# 不加 --keepParent：让 App 与说明文件都躺在压缩包根目录，
# 解压出来就是「一个 App + 一个说明」，不用再进一层目录找。
ditto -c -k --sequesterRsrc "$STAGE" "$ZIP"

BYTES="$(stat -f%z "$ZIP")"
MB="$(awk "BEGIN{printf \"%.1f\", $BYTES/1048576}")"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

echo "已生成：$ZIP"
echo "版本：$VERSION (build $BUILD)"
echo "大小：$BYTES 字节（$MB MB）"
echo "SHA-256：$SHA"
echo ""
echo "把这两行填进 Release 说明："
echo "| 文件 | \`MeetingScribe-${VERSION}-macOS.zip\`（$MB MB / $BYTES 字节） |"
echo "| SHA-256 | \`$SHA\` |"
