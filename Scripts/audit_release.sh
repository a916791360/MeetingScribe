#!/bin/zsh
# 分发前审计 —— 确认打包产物里没有夹带开发机的私人信息或凭据。
#
# 由来：曾经把开发机的私人目录路径（`Documents/Codex/<项目名>/…`）编译进了二进制，
# 随安装包一起发了出去。这类问题**代码审查看不出来**，只有对着产物扫一遍才会发现，
# 所以把关口放在产物的最后一道工序上（`package_app.sh` 签名之后自动调用）。
#
# 用法：
#   ./Scripts/audit_release.sh                  # 审计默认产物 .build/MeetingScribe.app
#   ./Scripts/audit_release.sh /path/to/App.app # 审计指定产物
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT_DIR/.build/MeetingScribe.app}"

if [[ ! -d "$APP" ]]; then
    print -u2 "找不到应用包：$APP"
    exit 1
fi

print "=== 分发前审计 ==="
print "产物：$APP"

fail=0

# ① 二进制里残留的开发机路径与凭据字样。
#    一律用 grep -E：BSD grep 的 `\|` 交替会**静默返回 0 行**，用它等于漏报。
scan_binary() {
    local bin="$1"
    [[ -f "$bin" ]] || return 0
    local hits
    hits=$(strings "$bin" 2>/dev/null \
        | grep -E 'Documents/Codex|crm-mall-flow|易运盈|/Users/[A-Za-z0-9._-]+/|sk-[A-Za-z0-9]{20,}' \
        | sort -u || true)
    if [[ -n "$hits" ]]; then
        print -u2 "✗ $(basename "$bin") 含可疑字符串："
        print -u2 -- "$hits"
        fail=1
    fi
}

scan_binary "$APP/Contents/MacOS/$(
    plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist" 2>/dev/null || print MeetingScribe
)"
scan_binary "$APP/Contents/Resources/whisper/bin/whisper-cli"

# ② 包内不应出现配置文件（Info.plist 是包自己的元数据，属预期）
stray=$(find "$APP" -type f \
    \( -name '*.json' -o -name '*.plist' -o -name '*.env' -o -name '*.yaml' -o -name '*.yml' \) \
    ! -name 'Info.plist' 2>/dev/null || true)
if [[ -n "${stray}" ]]; then
    print -u2 "✗ 包内含预期外的配置文件："
    print -u2 -- "${stray}"
    fail=1
fi

# ③ 动态库的 install name 不能指向作者机器（否则别人那边加载不到，同时也是路径泄露）
while IFS= read -r lib; do
    [[ -n "${lib}" ]] || continue
    name=$(otool -D "${lib}" 2>/dev/null | tail -1 || true)
    case "${name}" in
        */Users/*)
            print -u2 "✗ 动态库 install name 指向绝对路径：$(basename "${lib}") → ${name}"
            fail=1
            ;;
    esac
done <<< "$(find "$APP" -name '*.dylib' -type f 2>/dev/null || true)"

# ④ 文本资源里的凭据特征
cred=$(grep -rIl -E 'sk-[A-Za-z0-9]{20,}|apiKey|api_key' "$APP" 2>/dev/null || true)
if [[ -n "${cred}" ]]; then
    print -u2 "✗ 包内文本文件含凭据字样："
    print -u2 -- "${cred}"
    fail=1
fi

if [[ ${fail} -eq 0 ]]; then
    print "✓ 通过：无私人路径、无预期外配置文件、无凭据字样、依赖均为相对路径"
else
    print -u2 ""
    print -u2 "审计未通过 —— 先清理，别分发。"
fi

exit ${fail}
