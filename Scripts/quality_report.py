#!/usr/bin/env python3
"""速览 / 纪要 / 逐字稿 质量指标报告。

数据来源（都在本机，已 gitignore）：
  docs/verification/quality/cases/<caseId>.json   输入：逐字稿段
  docs/verification/quality/runs/<caseId>.json    输出：真实 Swift 管线跑出来的结果

用法：
  python3 Scripts/quality_report.py                 # 出报告
  python3 Scripts/quality_report.py --write-baseline  # 把当前结果存成基线
  python3 Scripts/quality_report.py --diff            # 与基线对比

指标口径见《转写与速览纪要质量提升方案》§5.1。凡本机无法算的指标，
本脚本**显式标注「不可算」并给出原因**，不用 0 冒充。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
QUALITY = REPO / "docs/verification/quality"
CASES = QUALITY / "cases"
RUNS = QUALITY / "runs"
BASELINE = QUALITY / "baseline.json"

# 空话动词：出现即扣分（方案 §5.1 目标 0 处）
EMPTY_PHRASES = [
    "会上介绍了", "会上讨论了", "会上提到", "谈到了", "提到了",
    "围绕", "展开", "延伸到", "中段主要围绕", "本次材料仅包含",
    "进行了讨论", "交换了意见",
]
# 元评论：模型在解释自己为什么写不出内容 —— 绝不该出现在「速览」里
META_PHRASES = ["未出现任何", "无法识别会议主题", "仅包含", "无法生成", "材料不足"]
NUMBERLIKE = re.compile(r"\d")
VERSIONLIKE = re.compile(r"v?\d+\.\d+(\.\d+)?")
HEADING = re.compile(r"^#{1,6}\s+\S", re.M)


def load_json(p: pathlib.Path):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def punctuation_ratio(segments: list[dict]) -> float:
    """有标点段占比：段文本里出现中文/西文句读的段数占比。"""
    if not segments:
        return 0.0
    marks = "，。！？；：、,.!?;:"
    hit = sum(1 for s in segments if any(m in s.get("text", "") for m in marks))
    return hit / len(segments)


def count_phrases(text: str, phrases: list[str]) -> int:
    return sum(text.count(p) for p in phrases)


def bullets_with_facts(bullets: list[str]) -> int:
    """要点里含数字 / 版本号 / 日期锚 的条数。"""
    n = 0
    for b in bullets:
        if NUMBERLIKE.search(b) or VERSIONLIKE.search(b):
            n += 1
        elif re.search(r"\[?\d{1,2}:\d{2}\]?", b):
            n += 1
    return n


def metrics_for(case: dict, run: dict | None) -> dict:
    m: dict = {"caseId": case["caseId"], "label": case["label"], "expect": case["expect"]}

    # ---------- 输入侧（逐字稿原始状态）----------
    raw = case["segments"]
    raw_chars = case["charCount"]
    m["inputSegments"] = case["segmentCount"]
    m["inputChars"] = raw_chars
    m["inputPunctRatio"] = round(punctuation_ratio(raw), 4)
    m["inputAvgChars"] = round(raw_chars / max(1, case["segmentCount"]), 1)
    m["durationSeconds"] = case["durationSeconds"]

    if run is None:
        m["status"] = "no-run"
        return m

    m["status"] = "ok" if run.get("ok") else "failed"
    m["errorType"] = run.get("errorType")
    m["elapsedSeconds"] = run.get("elapsedSeconds")
    m["finishReason"] = run.get("finishReason")
    m["degraded"] = bool(run.get("errorType"))
    m["transcriptCharsSentToModel"] = run.get("transcriptCharsSentToModel")

    # ---------- 逐字稿层（清洗后）----------
    pre_seg = run.get("preparedSegmentCount")
    pre_chars = run.get("preparedCharCount")
    if pre_seg:
        m["cleanedSegments"] = pre_seg
        m["segmentRatio"] = round(pre_seg / max(1, case["segmentCount"]), 4)
        m["cleanedAvgChars"] = round((pre_chars or 0) / max(1, pre_seg), 1)
    if pre_chars:
        m["charRetention"] = round(pre_chars / max(1, raw_chars), 4)

    # ---------- 速览层 / 纪要层 ----------
    a = run.get("analysis") or {}
    if run.get("ok") and a:
        ov = a.get("overviewText") or ""
        mn = a.get("minutesText") or ""
        bullets = a.get("overviewBullets") or []
        headline = a.get("headline") or ""
        decisions = a.get("decisions") or []
        actions = a.get("actions") or []

        m["headlineChars"] = len(headline)
        m["overviewChars"] = len(ov)
        m["overviewBulletCount"] = len(bullets)
        m["overviewBulletsWithFacts"] = bullets_with_facts(bullets)
        m["minutesChars"] = len(mn)
        m["minutesHeadings"] = len(HEADING.findall(mn))
        m["emptyPhraseCount"] = count_phrases(mn + ov + headline, EMPTY_PHRASES)
        m["metaCommentCount"] = count_phrases(ov + mn + headline, META_PHRASES)
        m["decisionCount"] = len(decisions)
        m["actionCount"] = len(actions)
        owners = [x for x in actions if (x.get("owner") or "").strip()]
        m["actionsWithOwner"] = len(owners)
        m["actionsWithOwnerRatio"] = round(len(owners) / max(1, len(actions)), 4)
    else:
        # 失败/降级：速览与纪要必然为空 —— 这正是「内容非常差」的机器可读形态
        for k in (
            "overviewChars", "minutesChars", "minutesHeadings", "emptyPhraseCount",
            "overviewBulletCount", "overviewBulletsWithFacts", "headlineChars",
            "decisionCount", "actionCount", "actionsWithOwner", "actionsWithOwnerRatio",
            "metaCommentCount",
        ):
            m[k] = None

    return m


def thresholds() -> list[tuple[str, str, str]]:
    """(指标键, 目标描述, 判定函数名) —— 供 --diff 判定达标。"""
    return [
        ("segmentRatio", "≤ 0.25", "le"),
        ("charRetention", "≥ 0.95", "ge"),
        ("minutesChars", "≥ 1200", "ge"),
        ("minutesHeadings", "≥ 3", "ge"),
        ("emptyPhraseCount", "= 0", "eq0"),
        ("overviewChars", "250 ~ 500", "range"),
        ("overviewBulletsWithFacts", "≥ 2", "ge"),
        ("decisionCount", "≥ 12", "ge"),
        ("actionCount", "≥ 10", "ge"),
        ("actionsWithOwnerRatio", "≥ 0.30", "ge"),
        ("inputPunctRatio", "≥ 0.98", "ge"),
    ]


def check(key: str, val, kind: str) -> str:
    if val is None:
        return "不可算"
    if kind == "le":
        return "达标" if val <= 0.25 else "未达"
    if kind == "ge":
        target = {"charRetention": 0.95, "minutesChars": 1200, "minutesHeadings": 3,
                  "overviewBulletsWithFacts": 2, "decisionCount": 12,
                  "actionCount": 10, "actionsWithOwnerRatio": 0.30,
                  "inputPunctRatio": 0.98}[key]
        return "达标" if val >= target else "未达"
    if kind == "eq0":
        return "达标" if val == 0 else "未达"
    if kind == "range":
        return "达标" if 250 <= val <= 500 else "未达"
    return "?"


def build_report(rows: list[dict]) -> str:
    # 只统计「期望有内容」的 case（too-short 期望空态，不参与内容类指标达标判定）
    content_rows = [r for r in rows if r["expect"] == "content" and r["status"] == "ok"]
    lines: list[str] = ["# 质量指标报告", ""]
    lines.append(f"- case 总数：{len(rows)}（其中期望有内容：{sum(1 for r in rows if r['expect'] == 'content')}）")
    lines.append(f"- 成功跑完：{sum(1 for r in rows if r['status'] == 'ok')}　失败/降级：{sum(1 for r in rows if r['status'] == 'failed')}")
    fr = sorted({str(r.get('finishReason')) for r in rows if r.get('finishReason')})
    lines.append(f"- finish_reason 取值：{', '.join(fr) if fr else '（本轮未采集，P0-3 后才有）'}")
    lines.append("")

    lines.append("## 逐 case 明细")
    lines.append("")
    lines.append("| case | 时长 | 状态 | 段数(原始→清洗) | 标点段 | 字数保留 | 速览字 | 纪要字 | 小标题 | 空话 | 决策/待办 | 带owner |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        seg = f"{r['inputSegments']} → {r.get('cleanedSegments', '—')}"
        ret = f"{r['charRetention']:.0%}" if r.get("charRetention") is not None else "—"
        lines.append(
            f"| {r['caseId']} | {r['durationSeconds']:.0f}s | {r['status']}"
            f"{'(' + str(r['errorType']) + ')' if r.get('errorType') else ''} "
            f"| {seg} | {r['inputPunctRatio']:.0%} | {ret} | {r.get('overviewChars') if r.get('overviewChars') is not None else '—'} "
            f"| {r.get('minutesChars') if r.get('minutesChars') is not None else '—'} "
            f"| {r.get('minutesHeadings') if r.get('minutesHeadings') is not None else '—'} "
            f"| {r.get('emptyPhraseCount') if r.get('emptyPhraseCount') is not None else '—'} "
            f"| {r.get('decisionCount') if r.get('decisionCount') is not None else '—'}"
            f"/{r.get('actionCount') if r.get('actionCount') is not None else '—'} "
            f"| {r.get('actionsWithOwner') if r.get('actionsWithOwner') is not None else '—'} |"
        )
    lines.append("")

    lines.append("## 达标判定（仅统计成功且有内容的 case）")
    lines.append("")
    if not content_rows:
        lines.append("> 没有任何 case 成功产出内容 —— 这本身就是最强的信号：管线在整场降级。")
    else:
        lines.append("| 指标 | 目标 | 实测（中位/最差） | 判定 |")
        lines.append("|---|---|---|---|")
        for key, target, kind in thresholds():
            vals = [r[key] for r in content_rows if r.get(key) is not None]
            if not vals:
                lines.append(f"| {key} | {target} | — | 不可算 |")
                continue
            vals_sorted = sorted(vals)
            med = vals_sorted[len(vals_sorted) // 2]
            worst = vals_sorted[0] if kind in ("ge",) else vals_sorted[-1]
            fmt = (lambda v: f"{v:.3f}")
            verdict = check(key, med, kind)
            lines.append(
                f"| {key} | {target} | {fmt(med)} / {fmt(worst)} | {verdict} |"
            )
    lines.append("")
    lines.append("## 本机不可算的指标（需要补充素材，不用 0 冒充）")
    lines.append("")
    lines.append("| 指标 | 为什么算不了 |")
    lines.append("|---|---|")
    lines.append("| 领域专名命中率 | 需要人工标注一份「本场正确专名表」，属阶段 0-1 的人工金标准工作 |")
    lines.append("| LLM 裁判四维（忠实度/覆盖度/密度/可执行性） | 阶段 3-3 的脚本，需调用不同厂商裁判模型 |")
    lines.append("| 分章路径相关指标 | 现有素材最长逐字稿 13037 字符 < 分章阈值 24000，路径未被触发 |")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write-baseline", action="store_true")
    ap.add_argument("--diff", action="store_true")
    args = ap.parse_args()

    cases = sorted(CASES.glob("*.json")) if CASES.is_dir() else []
    if not cases:
        print("没有评测集。先跑：python3 Scripts/build_eval_set.py", file=sys.stderr)
        return 1

    rows = []
    for cp in cases:
        case = load_json(cp)
        if not case:
            continue
        run = load_json(RUNS / f"{case['caseId']}.json")
        rows.append(metrics_for(case, run))

    report = build_report(rows)
    (QUALITY / "report.md").write_text(report, encoding="utf-8")
    (QUALITY / "report.json").write_text(
        json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print(report)

    if args.write_baseline:
        BASELINE.write_text(
            json.dumps({"rows": rows}, ensure_ascii=False, indent=1), encoding="utf-8"
        )
        print(f"\n已写入基线 → {BASELINE.relative_to(REPO)}")

    if args.diff:
        base = load_json(BASELINE)
        if not base:
            print("\n没有基线可对比。先跑 --write-baseline。", file=sys.stderr)
            return 1
        bmap = {r["caseId"]: r for r in base["rows"]}
        print("\n## 与基线对比")
        print("")
        print("| case | 指标 | 基线 | 现在 | 变化 |")
        print("|---|---|---|---|---|")
        for r in rows:
            b = bmap.get(r["caseId"], {})
            for key in ("cleanedSegments", "minutesChars", "minutesHeadings",
                        "emptyPhraseCount", "overviewChars", "decisionCount",
                        "actionCount", "actionsWithOwner"):
                bv, nv = b.get(key), r.get(key)
                if bv is None and nv is None:
                    continue
                if bv == nv:
                    continue
                delta = "—"
                if isinstance(bv, (int, float)) and isinstance(nv, (int, float)):
                    delta = f"{nv - bv:+g}"
                print(f"| {r['caseId']} | {key} | {bv} | {nv} | {delta} |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
