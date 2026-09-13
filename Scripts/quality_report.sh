#!/usr/bin/env bash
# 质量指标一条命令。
#
#   Scripts/quality_report.sh              只看已有结果是怎样（离线）
#   Scripts/quality_report.sh --run        先跑一遍真实管线（需要 MS_E2E_KEY），再出指标
#   Scripts/quality_report.sh --baseline   把当前结果存成基线
#   Scripts/quality_report.sh --diff       与基线对比
#
# 评测集不在仓库里（含真实会议内容）。首次使用先跑：
#   python3 Scripts/build_eval_set.py
set -euo pipefail

cd "$(dirname "$0")/.."

PY="${PYTHON:-python3}"
DO_RUN=0
PY_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --run)      DO_RUN=1 ;;
    --baseline) PY_ARGS+=(--write-baseline) ;;
    --diff)     PY_ARGS+=(--diff) ;;
    *)          PY_ARGS+=("$arg") ;;
  esac
done

if [[ ! -d docs/verification/quality/cases ]]; then
  echo "还没有评测集，正在构建…"
  "$PY" Scripts/build_eval_set.py
fi

if [[ "$DO_RUN" == "1" ]]; then
  if [[ -z "${MS_E2E_KEY:-}" ]]; then
    echo "MS_E2E_KEY 未设置，无法跑真实管线。" >&2
    exit 2
  fi
  echo "== 跑真实管线（会调用总结模型，按 case 数计费）=="
  swift test --disable-sandbox --filter QualityEvalTests
fi

echo
echo "== 指标报告 =="
"$PY" Scripts/quality_report.py "${PY_ARGS[@]}"
