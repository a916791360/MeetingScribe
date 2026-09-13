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
# 两套语料的分工：
#   docs/verification/quality/            真实会议，含客户名 → gitignore，只在你这台机器上有
#   docs/verification/quality/synthetic/  编造的会议      → 提交进仓库，CI 用它
# 指标口径只有一份（Scripts/quality_report.py），两套语料共用，避免口径漂移。
set -euo pipefail

cd "$(dirname "$0")/.."

PY="${PYTHON:-python3}"
DO_RUN=0
DO_JUDGE=0
CORPUS="${MS_QUALITY_ROOT:-docs/verification/quality}"
PY_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --run)       DO_RUN=1 ;;
    --judge)     DO_JUDGE=1 ;;
    --synthetic) CORPUS="docs/verification/quality/synthetic" ;;
    # --check 只对合成语料有意义（期望文件跟着合成语料走），所以它自带 --synthetic。
    --check)     CORPUS="docs/verification/quality/synthetic"; PY_ARGS+=(--check) ;;
    --baseline)  PY_ARGS+=(--write-baseline) ;;
    --diff)      PY_ARGS+=(--diff) ;;
    *)           PY_ARGS+=("$arg") ;;
  esac
done

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
  "$PY" Scripts/llm_judge.py --corpus "$CORPUS"
fi
