#!/bin/zsh
# 阶段 5-2：把 MeetingScribe 签成能给别人安装的版本（Developer ID + 硬运行时 + 公证 + 装订）。
#
# 为什么需要这个脚本
#   现在 `package_app.sh` 用的是本机自签证书 `PM Studio Signing`。自签的应用在
#   别人机器上会被 Gatekeeper 拦下来（"无法验证开发者"），也就是**装不上**。
#   要让别人装得上，必须：Developer ID 证书签名 → 硬运行时 → 送 Apple 公证 → 装订票据。
#
# 用之前你要做的三件事（只需要做一次）
#   1) 加入 Apple Developer Program（个人 99 美元/年），在 Xcode → Settings → Accounts
#      里登录，然后 Manage Certificates → 加一张 **Developer ID Application** 证书。
#      装好之后本命令能列出它：security find-identity -v -p codesigning
#   2) 生成一个 App 专用密码：appleid.apple.com → 登录与安全 → App 专用密码。
#      然后把这套凭据存进钥匙串（交互式，只需一次）：
#        xcrun notarytool store-credentials "MeetingScribeNotary" \
#          --apple-id "你的AppleID邮箱" --team-id "你的TeamID" --password "专用密码"
#      存好之后本脚本就只按名字引用它，**不会**再碰你的密码。
#   3) 确认 notarytool 可用（macOS 15 自带）：xcrun notarytool --version
#
# 用法
#   ./Scripts/notarize_app.sh --check                     # 只体检，不动任何东西
#   ./Scripts/notarize_app.sh --profile MeetingScribeNotary
#
# 参数
#   --profile NAME    钥匙串里的公证凭据名（第 2 步存的；默认 MeetingScribeNotary）
#   --identity NAME   签名身份（默认自动挑唯一的 "Developer ID Application"）
#   --check           只检查前置条件，不打包、不签名、不提交
#   --skip-package    复用已有的 .build/MeetingScribe.app，不重新打包

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MeetingScribe"
APP_DIR="${APP_DIR:-$ROOT_DIR/.build/$APP_NAME.app}"
ENTITLEMENTS="$ROOT_DIR/Packaging/MeetingScribe.entitlements"

PROFILE="${NOTARY_PROFILE:-MeetingScribeNotary}"
IDENTITY="${SIGNING_IDENTITY:-}"
CHECK_ONLY=0
SKIP_PACKAGE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        --check) CHECK_ONLY=1; shift ;;
        --skip-package) SKIP_PACKAGE=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) print -u2 "未知参数：$1"; exit 2 ;;
    esac
done

FAIL=0
ok()   { print "  ✅ $1" }
bad()  { print "  ❌ $1"; FAIL=1 }
warn() { print "  ⚠️  $1" }

print "=== 阶段 5-2 前置条件体检 ==="

# 1) Developer ID 证书
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [[ -n "$IDENTITY" && "$IDENTITY" == Developer\ ID\ Application:* ]]; then
    ok "签名身份：$IDENTITY"
else
    bad "没找到 Developer ID Application 证书（当前只能是本机自签，别人装不上）"
    print "     → Xcode → Settings → Accounts → Manage Certificates → 加一张 Developer ID Application"
fi

# 2) 公证凭据
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    ok "公证凭据「$PROFILE」可用"
else
    bad "钥匙串里没有公证凭据「$PROFILE」（或凭据无效）"
    print "     → xcrun notarytool store-credentials \"$PROFILE\" --apple-id <邮箱> --team-id <TeamID> --password <App专用密码>"
fi

# 3) 其它
[[ -f "$ENTITLEMENTS" ]] && ok "entitlements：Packaging/MeetingScribe.entitlements" \
                         || bad "缺 Packaging/MeetingScribe.entitlements"
if xcrun notarytool --version >/dev/null 2>&1; then
    ok "notarytool $(xcrun notarytool --version 2>/dev/null | head -1)"
else
    bad "notarytool 不可用"
fi
[[ -d "$ROOT_DIR/Resources/Assets.xcassets" ]] && ok "图标资源齐全" || bad "缺 Resources/Assets.xcassets"

if [[ $FAIL -ne 0 ]]; then
    print ""
    print "前置条件未满足，停止。上面标 ❌ 的每一项都要先解决。"
    exit 1
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
    print ""
    print "体检通过，可以正式跑：./Scripts/notarize_app.sh --profile $PROFILE"
    exit 0
fi

if [[ $SKIP_PACKAGE -eq 0 ]]; then
    print ""
    print "=== 1/5 打包（用 Developer ID 签名）==="
    SIGNING_IDENTITY="$IDENTITY" "$ROOT_DIR/Scripts/package_app.sh"
fi

if [[ ! -d "$APP_DIR" ]]; then
    print -u2 "找不到 $APP_DIR"
    exit 1
fi

print ""
print "=== 2/5 由内向外重签（硬运行时 + 时间戳 + entitlements）==="
# Apple 要求公证的每个 Mach-O 都带硬运行时与安全时间戳，且**由内向外**签：
# 先签 Resources 里的 dylib / 辅助可执行文件（whisper-cli），最后才签外层 .app。
# 顺序反了的话，外层签名会因为内层后来被改动而失效。
SIGN_ARGS=(--force --options runtime --timestamp)
SIGNED_INNER=0
for bin in "$APP_DIR"/Contents/Resources/whisper/bin/*(.N); do
    [[ -f "$bin" ]] || continue
    case "$bin" in
        *.dylib|*/whisper-cli)
            codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$bin"
            SIGNED_INNER=$((SIGNED_INNER + 1))
            ;;
    esac
done
print "  已签内层文件：$SIGNED_INNER 个"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_DIR"
print "  已签外层 .app"

print ""
print "=== 3/5 校验签名 ==="
codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -3
codesign -d --entitlements - "$APP_DIR" 2>/dev/null | tail -5 || true

print ""
print "=== 4/5 提交公证（要等 Apple 返回，通常 1~5 分钟）==="
ZIP_PATH="$(mktemp -d /private/tmp/meetingscribe-notary.XXXXXX)/$APP_NAME.zip"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$PROFILE" --wait

print ""
print "=== 5/5 装订票据 + 最终校验 ==="
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
# Gatekeeper 的实际判定（这一步通过才说明别人双击能打开）
if spctl --assess --type execute --verbose=4 "$APP_DIR" 2>&1 | tail -4; then
    print ""
    print "✅ 完成。这个 $APP_NAME.app 可以分发给别人了。"
else
    print ""
    print "❌ spctl 判定仍未通过，不要分发。把上面的输出贴出来。"
    exit 1
fi
