#!/usr/bin/env bash
# 质量指标一条命令。
#
#   Scripts/quality_report.sh              只看已有结果是怎样（离线，真实语料）
#   Scripts/quality_report.sh --synthetic  换合成语料出报告（免密、可提交、CI 同款）
#   Scripts/quality_report.sh --check      合成语料自测：判定与期望不一致就非零退出（CI 用）
#   Scripts/quality_report.sh --run        先跑一遍真实管线（需要 MS_E2E_KEY），再出指标
#   Scripts/quality_report.sh --baseline   把当前结果存成基线
#   Scripts/quality_report.sh --diff       与基线对比
#   Scripts/quality_report.sh --judge      调**异厂**模型当裁判，给四维打分（需要裁判 Key）
#
# 裁判专属参数单独转发给 llm_judge.py（指标脚本不认识它们，混在一起会直接报错）：
#   --repeat N            每维调用 N 次取中位。**单次 LLM 打分有 ±1 抖动，
#                         要拿分数当 Gate 依据就必须用 --repeat 3**
#   --cases a,b           只评这几个 case（省钱）
#   --dry-run             只打印提示词，不调模型（检查路由与提示词用这个，不花钱）
#   --model / --base-url / --allow-same-vendor
#
# 例：
#   Scripts/quality_report.sh --judge --repeat 3    # Gate 决策用的那一跑（慢，会调很多次模型）
#   Scripts/quality_report.sh --judge --dry-run     # 不花钱，先看提示词与参数转发对不对
#
# 两套语料的分工：
#   docs/verification/quality/            真实会议，含客户名 → gitignore，只在你这台机器上有
#   docs/verification/quality/synthetic/  编造的会议      → 提交进仓库，CI 用它
# 指标口径只有一份（Scripts/quality_report.py），两套语料共用，避免口径漂移。
set -euo pipefail

cd "$(dirname "$0")/.."

PY="${PYTHON:-python3}"
DO_RUN=0
DO_JUDGE=0
DO_CHECK=0
CORPUS="${MS_QUALITY_ROOT:-docs/verification/quality}"
PY_ARGS=()
JUDGE_ARGS=()

# macOS 自带的是 bash 3.2，别用 bash 4 的语法（`mapfile`、`${var,,}` 之类都没有）。
# 变量一律写 ${VAR}：中文标点紧跟变量名时会被吃进变量名（见 .learnings LRN-20260914-021）。
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)       DO_RUN=1; shift ;;
    --judge)     DO_JUDGE=1; shift ;;
    --synthetic) CORPUS="docs/verification/quality/synthetic"; shift ;;
    # --check 只对合成语料有意义（期望文件跟着合成语料走），所以它自带 --synthetic。
    --check)     DO_CHECK=1
                 CORPUS="docs/verification/quality/synthetic"
                 PY_ARGS+=(--check); shift ;;
    --baseline)  PY_ARGS+=(--write-baseline); shift ;;
    --diff)      PY_ARGS+=(--diff); shift ;;
    # ---- 以下转发给 llm_judge.py
    --repeat)    JUDGE_ARGS+=(--repeat "${2:?--repeat 需要一个数字}"); shift 2 ;;
    --cases)     JUDGE_ARGS+=(--cases "${2:?--cases 需要 caseId 列表}"); shift 2 ;;
    --model)     JUDGE_ARGS+=(--model "${2:?--model 需要一个模型名}"); shift 2 ;;
    --base-url)  JUDGE_ARGS+=(--base-url "${2:?--base-url 需要一个地址}"); shift 2 ;;
    --dry-run)   JUDGE_ARGS+=(--dry-run); shift ;;
    --allow-same-vendor) JUDGE_ARGS+=(--allow-same-vendor); shift ;;
    *)           PY_ARGS+=("$1"); shift ;;
  esac
done

# 只写了裁判参数、忘了 --judge 时（比如 `--repeat 3` 单独出现），
# 静默忽略比报错更危险 —— 会让人以为「跑了 3 次」，其实一次没跑。
if [[ ${#JUDGE_ARGS[@]} -gt 0 ]]; then
  DO_JUDGE=1
fi

if [[ "$DO_JUDGE" == "1" && "$DO_CHECK" == "1" ]]; then
  echo "提示：--check 自带 --synthetic（那是**指标**门禁的语料），" >&2
  echo "      而裁判的分数只在**真实语料**上才有意义，所以没有把 --check 转给裁判。" >&2
fi

if [[ "$DO_RUN" == "1" ]]; then
  if [[ -z "${MS_E2E_KEY:-}" ]]; then
    echo "MS_E2E_KEY 未设置，无法跑真实管线。" >&2
    exit 2
  fi
  if [[ ! -d docs/verification/quality/cases ]]; then
    echo "还没有真实评测集，正在构建…"
    "$PY" Scripts/build_eval_set.py
  fi
  echo "== 跑真实管线（会调用总结模型，按 case 数计费）=="
  swift test --disable-sandbox --filter QualityEvalTests
fi

echo
echo "== 指标报告（语料：${CORPUS}）=="
# macOS 自带的是 bash 3.2：`set -u` 下展开空数组会报 unbound variable，
# 所以用 `${arr[@]+...}` 这个兼容写法，而不是直接 `"${PY_ARGS[@]}"`。
"$PY" Scripts/quality_report.py --corpus "$CORPUS" ${PY_ARGS[@]+"${PY_ARGS[@]}"}

if [[ "$DO_JUDGE" == "1" ]]; then
  echo
  echo "== LLM 裁判（异厂模型，四维打分）=="
  "$PY" Scripts/llm_judge.py --corpus "$CORPUS" ${JUDGE_ARGS[@]+"${JUDGE_ARGS[@]}"}
fi
