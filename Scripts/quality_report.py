#!/usr/bin/env python3
"""速览 / 纪要 / 逐字稿 质量指标报告。

语料根由 `--corpus` 或环境变量 `MS_QUALITY_ROOT` 指定，默认 `docs/verification/quality/`。
一套语料 = 一个目录，里面三样东西：

  cases/<caseId>.json        输入：逐字稿段（真实语料已 gitignore；合成语料在仓库里）
  runs/<caseId>.json         输出：管线跑出来的结果
  expectations.json          可选：`--check` 用的期望判定（只有合成语料有）

用法：
  python3 Scripts/quality_report.py                    # 出报告
  python3 Scripts/quality_report.py --write-baseline   # 把当前结果存成基线
  python3 Scripts/quality_report.py --diff             # 与基线对比
  python3 Scripts/quality_report.py --corpus docs/verification/quality/synthetic --check
        # 合成语料自测：逐条比对 expectations.json，不一致就退出码 1（CI 用）

指标口径见《转写与速览纪要质量提升方案》§5.1。凡本机无法算的指标，
本脚本**显式标注「不可算」并给出原因**，不用 0 冒充。
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_ROOT = REPO / "docs/verification/quality"

# 语料根（`--corpus` / `MS_QUALITY_ROOT` 覆盖，见 configure_root）。
QUALITY = DEFAULT_ROOT
CASES = QUALITY / "cases"
RUNS = QUALITY / "runs"
BASELINE = QUALITY / "baseline.json"
EXPECTATIONS = QUALITY / "expectations.json"
REPORT_MD = QUALITY / "report.md"
REPORT_JSON = QUALITY / "report.json"


def configure_root(root: pathlib.Path) -> None:
    """把语料根切到 `root`。

    合成语料与真实语料**共用同一套指标代码** —— 这正是不把指标逻辑抄第二份的理由：
    一抄就两边口径漂移，而口径漂移在这个项目里已经把人带去修没坏的东西 6 次了。
    """
    global QUALITY, CASES, RUNS, BASELINE, EXPECTATIONS, REPORT_MD, REPORT_JSON
    QUALITY = pathlib.Path(root).resolve()
    CASES = QUALITY / "cases"
    RUNS = QUALITY / "runs"
    BASELINE = QUALITY / "baseline.json"
    EXPECTATIONS = QUALITY / "expectations.json"
    REPORT_MD = QUALITY / "report.md"
    REPORT_JSON = QUALITY / "report.json"


def rel(p: pathlib.Path) -> str:
    """相对仓库根的展示路径；不在仓库里就退化成绝对路径。"""
    try:
        return str(p.relative_to(REPO))
    except ValueError:
        return str(p)

# 空话动词：出现即扣分（方案 §5.1 目标 0 处）
EMPTY_PHRASES = [
    "会上介绍了", "会上讨论了", "会上提到", "谈到了", "提到了",
    "延伸到", "本次材料仅包含",
    "进行了讨论", "交换了意见",
]
# 「围绕……展开」这条**必须按句式匹配，不能裸词匹配**。
# 实测（2026-09-13，阶段 1 复评）：slice1 里
#   「后续给用户表现的形态也要围绕问答、视频和远程协助展开」
# 是**实质内容**，却因为同时含「围绕」和「展开」被算成 2 处空话，直接把这一场
# 判成未达标。空话的真正形态是**句首起兴**：「本次会议围绕 X 展开」。
# 结论：指标口径错会把人带去修没坏的东西 —— 同《执行计划》§1.5 小标题那次。
EMPTY_PATTERNS = [
    re.compile(r"(?:^|[\n。；])\s*(?:本次|这次)?(?:会议|讨论|交流)?\s*围绕[^。；\n]{0,40}展开"),
]
# 元评论：模型在解释自己为什么写不出内容 —— 绝不该出现在「速览」里。
# 这些措辞是 2026-09-13 基线跑出来的**实测原话**（超短误录那一场），不是猜的：
#   「本次输入材料中不包含任何工作会议内容…」
#   「## 材料情况说明」「## 处理建议」「当前材料不足以生成纪要正文」
META_PHRASES = [
    "不包含任何", "未出现任何", "无法识别会议主题", "仅包含", "无法生成",
    "材料不足", "材料情况说明", "处理建议", "不足以生成", "无法整理",
    "不对会议主题", "不存在可供归纳", "为避免编造",
]
NUMBERLIKE = re.compile(r"\d")
VERSIONLIKE = re.compile(r"v?\d+\.\d+(\.\d+)?")
# 小标题识别。**不能只认 markdown `#`** —— 基线跑出来模型用的是中文序号
# （「一、MVP现状与知识库」），只认 `#` 会把「有 5 个小节」误报成 0，那是口径错不是内容错。
HEADING = re.compile(
    r"^(?:#{1,6}\s+\S"                        # markdown 标题
    r"|[一二三四五六七八九十]+[、．.]"            # 一、二、
    r"|第[一二三四五六七八九十百]+[章节部分]"        # 第一章 / 第二部分
    r"|[（(][一二三四五六七八九十]+[）)])"          # （一）
    , re.M)


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


def count_empty_phrases(text: str) -> int:
    """空话命中数 = 裸词表 + 句式表（见 EMPTY_PATTERNS 的口径说明）。"""
    return count_phrases(text, EMPTY_PHRASES) + sum(len(p.findall(text)) for p in EMPTY_PATTERNS)


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
    # 两段式：速览 / 纪要是两次独立调用，`finish_reason` 分开记。
    m["finishReason"] = run.get("finishReason")
    m["minutesFinishReason"] = run.get("minutesFinishReason")
    m["escalationCount"] = run.get("escalationCount")
    m["partialNotice"] = run.get("partialNotice")
    m["degraded"] = bool(run.get("errorType"))
    m["transcriptCharsSentToModel"] = run.get("transcriptCharsSentToModel")

    # ---------- 逐字稿层（清洗后）----------
    pre_seg = run.get("preparedSegmentCount")
    pre_chars = run.get("preparedCharCount")
    if pre_seg:
        m["cleanedSegments"] = pre_seg
        m["segmentRatio"] = round(pre_seg / max(1, case["segmentCount"]), 4)
        m["cleanedAvgChars"] = round((pre_chars or 0) / max(1, pre_seg), 1)
        # ⚠️ 口径说明（2026-09-13，阶段 1 复评时加）：
        # 「后处理把碎片/复读折叠掉」这件事**只对本来就很碎的转录有意义**。
        # slice1 的原始转录本来就是句子级（约 10.6 段/分钟、94% 带标点），没有可折叠的
        # 东西，比值自然接近 1 —— 那不是"后处理没生效"，是**这个指标不适用**。
        # 所以达标判定只在「病态密度」（≥15 段/分钟）的 case 上做，其余如实记 None。
        density = case["segmentCount"] / max(1e-6, case["durationSeconds"] / 60.0)
        m["inputSegmentsPerMinute"] = round(density, 1)
        m["segmentRatioJudged"] = m["segmentRatio"] if density >= 15 else None
    if pre_chars:
        # ⚠️ 口径说明（2026-09-13，P0-1 落地时改）：
        # `charRetention` 是「清洗后 / 原始」，而**复读折叠本身就该丢掉约一成的字**
        # （阶段 0 实测复读占 10.4% 的段）。所以它一定会掉到 0.95 以下，
        # 拿它判「有没有删过头」是假阴性 —— 它只作参考，不参与达标判定。
        m["charRetention"] = round(pre_chars / max(1, raw_chars), 4)
    # 真正的「删没删过头」判据：拿**去重之后**的字数当分母。
    dedup_chars = run.get("dedupCharCount")
    if dedup_chars and pre_chars:
        m["dedupCharCount"] = dedup_chars
        m["dedupLossRatio"] = round(1 - dedup_chars / max(1, raw_chars), 4)
        m["uniqueCharRetention"] = round(pre_chars / max(1, dedup_chars), 4)

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
        m["emptyPhraseCount"] = count_empty_phrases(mn + ov + headline)
        m["metaCommentCount"] = count_phrases(ov + mn + headline, META_PHRASES)
        m["decisionCount"] = len(decisions)
        m["actionCount"] = len(actions)
        # ⚠️ 口径说明（2026-09-13，2A 复评时加，第 5 次同型修正）：
        # 「决策 ≥12 / 待办 ≥10」是**绝对条数**，其出处是方案 §2.4 那次实验 ——
        # 在**同一场 44.6 分钟的长会**上量到的 15 / 12（方案 L188，材料见 L72/L139）。
        # 把绝对条数套到 15 分钟切片上，等于要求切片和整场一样多，必然「未达」；
        # 而四个 case 的**条数密度其实很接近**（见 decisionPerHour / actionPerHour，
        # 17/0.74h≈23、10/0.25h≈40、7/0.24h≈29、6/0.25h≈24）。
        # 所以只在「时长够得上这个目标」的 case（≥40 分钟）上判，其余如实记 None ——
        # 与 segmentRatioJudged 同一套做法。原始绝对条数照旧保留在 decisionCount / actionCount。
        hours = max(1e-6, case["durationSeconds"] / 3600.0)
        m["decisionPerHour"] = round(len(decisions) / hours, 1)
        m["actionPerHour"] = round(len(actions) / hours, 1)
        long_enough = case["durationSeconds"] >= 2400
        m["decisionCountJudged"] = m["decisionCount"] if long_enough else None
        m["actionCountJudged"] = m["actionCount"] if long_enough else None
        # ⚠️ 这两个字段要等阶段 2（2A 数据模型）才会有。字段不存在时**必须报「不可算」**，
        # 不能用 0 冒充 —— 否则「功能还没做」会被读成「做了但效果差」，
        # 阶段 0 已经在这类假阴性上栽过一次（小标题、元评论）。
        if any("owner" in x for x in actions):
            owners = [x for x in actions if (x.get("owner") or "").strip()]
            m["actionsWithOwner"] = len(owners)
            m["actionsWithOwnerRatio"] = round(len(owners) / max(1, len(actions)), 4)
        else:
            m["actionsWithOwner"] = None
            m["actionsWithOwnerRatio"] = None
        if "overviewBullets" in a:
            m["overviewBulletCount"] = len(bullets)
            m["overviewBulletsWithFacts"] = bullets_with_facts(bullets)
        else:
            m["overviewBulletCount"] = None
            m["overviewBulletsWithFacts"] = None
        # 2A 的另两个字段同理：键不在 = 「字段还没落地」，报不可算，不用 0 冒充。
        m["headlineChars"] = len(headline.strip()) if "headline" in a else None
        m["openQuestionCount"] = (
            len(a.get("openQuestions") or []) if "openQuestions" in a else None
        )
    else:
        # 失败/降级：速览与纪要必然为空 —— 这正是「内容非常差」的机器可读形态
        for k in (
            "overviewChars", "minutesChars", "minutesHeadings", "emptyPhraseCount",
            "overviewBulletCount", "overviewBulletsWithFacts", "headlineChars",
            "openQuestionCount",
            "decisionCount", "actionCount", "actionsWithOwner", "actionsWithOwnerRatio",
            "metaCommentCount",
        ):
            m[k] = None

    return m


def thresholds() -> list[tuple[str, str, str, object]]:
    """(指标键, 目标描述, 判定方式, 阈值) —— 判定与展示共用一个来源。

    ⚠️ 阈值**只在这里写一次**（2026-09-14，阶段 3-2 时改）。
    旧版把 0.95 / 1200 / 3 / 2 / 12 / 10 / 0.30 在 `thresholds()` 与 `check()`
    里各写了一遍，改目标值要记得改两处 —— 而"同一判据出现在第 2 处就必须抽函数"
    是这个项目反复栽跟头后的铁律。这里把阈值并进元组，`check()` 不再自己认数字。
    """
    return [
        # 「删没删过头」看的是去重之后的保留率；charRetention（对原始字数）只作参考，
        # 因为复读占一成、按设计就该丢，见 metrics_for 里的口径说明。
        # segmentRatio 也只在「本来就很碎」的 case 上判（slice1 那种句子级转录不适用）。
        ("segmentRatioJudged", "≤ 0.25（仅病态密度 case）", "le", 0.25),
        ("uniqueCharRetention", "≥ 0.95", "ge", 0.95),
        ("minutesChars", "≥ 1200", "ge", 1200),
        ("minutesHeadings", "≥ 3", "ge", 3),
        ("emptyPhraseCount", "= 0", "eq0", 0),
        ("overviewChars", "250 ~ 500", "range", (250, 500)),
        ("overviewBulletsWithFacts", "≥ 2", "ge", 2),
        ("decisionCountJudged", "≥ 12（仅 ≥40 分钟 case）", "ge", 12),
        ("actionCountJudged", "≥ 10（仅 ≥40 分钟 case）", "ge", 10),
        ("actionsWithOwnerRatio", "≥ 0.30", "ge", 0.30),
        # ⚠️ `inputPunctRatio` **故意不参与达标判定**（2026-09-13，1D 补测时改）：
        # 它量的是**输入素材自己的标点**，不是产品产出。而离线评测喂的是**已经转写好的
        # 逐字稿** —— 转写参数（1D）在整条链路上根本没被执行，所以这个数字无论好坏
        # 都不反映产品。它的真实判决来自「同一段音频、只动 1D 三个变量」的三臂对照
        # （见《执行计划》「1D 补测结果」：旧参数 1.6% → 新参数 94.7%）。
        # 数字照旧打在明细表的「标点段」列里，但只作素材画像，不判达标。
    ]


def check(key: str, val, kind: str, target=None) -> str:
    """判定。`kind == "ge"` 时 target 就是下限（不再从硬编码字典里查）。"""
    if val is None:
        return "不可算"
    if kind == "le":
        return "达标" if val <= target else "未达"
    if kind == "ge":
        return "达标" if val >= target else "未达"
    if kind == "eq0":
        return "达标" if val == target else "未达"
    if kind == "range":
        lo, hi = target
        return "达标" if lo <= val <= hi else "未达"
    return "?"


def verdict_of(key: str, val) -> str:
    """按指标键取判定。阈值只在 `thresholds()` 里写一次，这里不认数字。"""
    for k, _desc, kind, target in thresholds():
        if k == key:
            return check(k, val, kind, target)
    raise KeyError(f"{key} 不是受判指标；要钉数值请用 expectations 里的 assert")


def empty_state_verdict(row: dict) -> str:
    """期望空态的 case 判成什么。

    ⚠️ 抽成函数（2026-09-14，阶段 3-2）：报告表格与 `--check` 都用它，
    否则「CI 认为达标」和「报告里写达标」会变成两份各自维护的判据。
    """
    meta = row.get("metaCommentCount")
    if meta is None:
        return "不可算"
    if meta > 0:
        return "未达（产出了元评论）"
    if (row.get("overviewChars") or 0) + (row.get("minutesChars") or 0) == 0:
        return "达标（干净空态）"
    return "存疑（有内容但无元评论关键词，需人工看）"


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
    lines.append(
        "> `去重保留` = 清洗后字数 / 去重后字数 —— **这才是「有没有删过头」的判据**（要 ≥95%）。"
        "`字数保留` = 清洗后字数 / 原始字数，复读占一成、按设计就该丢，只作参考。"
    )
    lines.append("")
    lines.append("| case | 时长 | 状态 | 段数(原始→清洗) | 标点段 | 去重保留 | 字数保留 | 速览字 | 纪要字 | 小标题 | 空话 | 元评论 | 结论字 | 要点 | 待确认 | 决策/待办 | 带owner |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        dens = r.get("inputSegmentsPerMinute")
        seg = f"{r['inputSegments']} → {r.get('cleanedSegments', '—')}"
        if dens is not None:
            seg += f" ({dens:.1f}/min)"
        ret = f"{r['charRetention']:.0%}" if r.get("charRetention") is not None else "—"
        uniq = f"{r['uniqueCharRetention']:.0%}" if r.get("uniqueCharRetention") is not None else "—"
        lines.append(
            f"| {r['caseId']} | {r['durationSeconds']:.0f}s | {r['status']}"
            f"{'(' + str(r['errorType']) + ')' if r.get('errorType') else ''} "
            f"| {seg} | {r['inputPunctRatio']:.0%} | {uniq} | {ret} "
            f"| {r.get('overviewChars') if r.get('overviewChars') is not None else '—'} "
            f"| {r.get('minutesChars') if r.get('minutesChars') is not None else '—'} "
            f"| {r.get('minutesHeadings') if r.get('minutesHeadings') is not None else '—'} "
            f"| {r.get('emptyPhraseCount') if r.get('emptyPhraseCount') is not None else '—'} "
            f"| {r.get('metaCommentCount') if r.get('metaCommentCount') is not None else '—'} "
            f"| {r.get('headlineChars') if r.get('headlineChars') is not None else '—'} "
            f"| {r.get('overviewBulletCount') if r.get('overviewBulletCount') is not None else '—'} "
            f"| {r.get('openQuestionCount') if r.get('openQuestionCount') is not None else '—'} "
            f"| {r.get('decisionCount') if r.get('decisionCount') is not None else '—'}"
            f"/{r.get('actionCount') if r.get('actionCount') is not None else '—'} "
            f"| {r.get('actionsWithOwner') if r.get('actionsWithOwner') is not None else '—'} |"
        )
    lines.append("")

    # 期望走空态的 case（材料太少）。P1-5 的验收就在这里：
    # 正确行为是「不产出内容、也不做元评论」，而不是产出一段解释自己为什么写不出来。
    empty_rows = [r for r in rows if r["expect"] == "emptyState"]
    if empty_rows:
        lines.append("## 期望空态的 case（P1-5 验收）")
        lines.append("")
        lines.append("| case | 速览字 | 纪要字 | 元评论命中 | 判定 |")
        lines.append("|---|---|---|---|---|")
        for r in empty_rows:
            oc, mc, meta = r.get("overviewChars"), r.get("minutesChars"), r.get("metaCommentCount")
            verdict = empty_state_verdict(r)
            lines.append(
                f"| {r['caseId']} | {oc if oc is not None else '—'} "
                f"| {mc if mc is not None else '—'} "
                f"| {meta if meta is not None else '—'} | {verdict} |"
            )
        lines.append("")

    lines.append("## 达标判定（仅统计成功且有内容的 case）")
    lines.append("")
    if not content_rows:
        lines.append("> 没有任何 case 成功产出内容 —— 这本身就是最强的信号：管线在整场降级。")
    else:
        lines.append("| 指标 | 目标 | 实测（中位/最差） | 判定 |")
        lines.append("|---|---|---|---|")
        for key, target, kind, tval in thresholds():
            vals = [r[key] for r in content_rows if r.get(key) is not None]
            if not vals:
                lines.append(f"| {key} | {target} | — | 不可算 |")
                continue
            vals_sorted = sorted(vals)
            med = vals_sorted[len(vals_sorted) // 2]
            worst = vals_sorted[0] if kind in ("ge",) else vals_sorted[-1]
            fmt = (lambda v: f"{v:.3f}")
            verdict = check(key, med, kind, tval)
            lines.append(
                f"| {key} | {target} | {fmt(med)} / {fmt(worst)} | {verdict} |"
            )
    lines.append("")
    lines.append("## 本机不可算的指标（需要补充素材，不用 0 冒充）")
    lines.append("")
    lines.append("| 指标 | 为什么算不了 |")
    lines.append("|---|---|")
    lines.append("| 领域专名命中率 | 需要人工标注一份「本场正确专名表」，属阶段 0-1 的人工金标准工作 |")
    lines.append("| LLM 裁判四维（忠实度/覆盖度/密度/可执行性） | **不在这份报告里**：它要调模型，跑 "
                 "`Scripts/llm_judge.py`（异厂裁判），产物落在 `<语料>/judge/report.md` |")
    lines.append("| 分章路径相关指标 | 现有素材最长逐字稿 13037 字符 < 分章阈值 24000，路径未被触发 |")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write-baseline", action="store_true")
    ap.add_argument("--diff", action="store_true")
    ap.add_argument("--check", action="store_true",
                    help="与 expectations.json 逐条比对判定，不一致退出码 1（CI 用）")
    ap.add_argument("--corpus", default=None,
                    help="语料根目录；默认取 MS_QUALITY_ROOT，再默认 docs/verification/quality")
    args = ap.parse_args()

    root = pathlib.Path(args.corpus) if args.corpus else pathlib.Path(
        os.environ.get("MS_QUALITY_ROOT", str(DEFAULT_ROOT)))
    configure_root(root)

    cases = sorted(CASES.glob("*.json")) if CASES.is_dir() else []
    if not cases:
        print(f"没有评测集：{rel(CASES)} 里没有 case。"
              f"真实语料先跑 python3 Scripts/build_eval_set.py；"
              f"合成语料直接看 docs/verification/quality/synthetic/。", file=sys.stderr)
        return 1

    rows = []
    for cp in cases:
        case = load_json(cp)
        if not case:
            continue
        run = load_json(RUNS / f"{case['caseId']}.json")
        rows.append(metrics_for(case, run))

    if args.check:
        return run_check(rows)

    report = build_report(rows)
    REPORT_MD.write_text(report, encoding="utf-8")
    REPORT_JSON.write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")
    print(report)

    if args.write_baseline:
        BASELINE.write_text(
            json.dumps({"rows": rows}, ensure_ascii=False, indent=1), encoding="utf-8"
        )
        print(f"\n已写入基线 → {rel(BASELINE)}")

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
            for key in ("finishReason", "cleanedSegments", "uniqueCharRetention",
                        "dedupLossRatio", "minutesChars", "minutesHeadings",
                        "emptyPhraseCount", "overviewChars", "decisionCount",
                        "actionCount", "actionsWithOwner", "metaCommentCount"):
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


def _cmp(val, op: str, want) -> bool:
    if val is None:
        return False
    if op == "eq":
        return val == want
    if op == "lt":
        return val < want
    if op == "le":
        return val <= want
    if op == "gt":
        return val > want
    if op == "ge":
        return val >= want
    raise ValueError(f"不认识的比较符：{op}")


def run_check(rows: list[dict]) -> int:
    """合成语料自测：算出来的判定必须与 `expectations.json` 逐条一致。

    这不是在测「模型好不好」——模型质量在 CI 里测不了。它测的是**尺子本身**：
    同一份输入经指标代码算出来，该达标的还达标、该未达的还判未达、该「不可算」的
    不许拿 0 冒充。回归一旦发生（比如有人把空话检测的句式匹配改回裸词匹配），
    这里会红，而不是等到某天读报告时才发现数字早就没意义了。
    """
    exp = load_json(EXPECTATIONS)
    if not exp:
        print(f"没有 {rel(EXPECTATIONS)} —— 这套语料不支持 --check。", file=sys.stderr)
        return 1
    spec = exp.get("cases", {})
    print(f"# 合成语料自测（{rel(QUALITY)}）")
    print("")
    print("| case | 指标 | 期望 | 实测 | 值 | 结果 |")
    print("|---|---|---|---|---|---|")

    failures: list[str] = []
    seen_keys = set()
    for r in rows:
        cid = r["caseId"]
        seen_keys.add(cid)
        want = spec.get(cid)
        if want is None:
            failures.append(f"{cid} 没有写进 expectations.json（新增 case 必须补期望）")
            print(f"| {cid} | — | — | — | — | ✗ 缺期望 |")
            continue

        # 1) 内容类：逐个受判指标对判定
        for key, want_verdict in (want.get("metrics") or {}).items():
            val = r.get(key)
            got = verdict_of(key, val)
            ok = got == want_verdict
            shown = val if val is not None else "—"
            print(f"| {cid} | {key} | {want_verdict} | {got} | {shown} | {'✓' if ok else '✗'} |")
            if not ok:
                failures.append(f"{cid}.{key} 期望「{want_verdict}」，实测「{got}」（值 {val}）")

        # 2) 空态类：case 级判定
        if want.get("emptyState"):
            got = empty_state_verdict(r)
            ok = got == want["emptyState"]
            print(f"| {cid} | （空态判定） | {want['emptyState']} | {got} | — | {'✓' if ok else '✗'} |")
            if not ok:
                failures.append(f"{cid} 空态期望「{want['emptyState']}」，实测「{got}」")

        # 3) 数值断言：不参与阈值的指标也要能钉住（如 preparedSegmentCount 回退）
        for a in want.get("assert") or []:
            val = r.get(a["key"])
            ok = _cmp(val, a["op"], a["value"])
            print(f"| {cid} | {a['key']} | {a['op']} {a['value']} | {val} | — | {'✓' if ok else '✗'} |")
            if not ok:
                failures.append(
                    f"{cid}.{a['key']} 期望 {a['op']} {a['value']}，实测 {val}")

    for cid in spec:
        if cid not in seen_keys:
            failures.append(f"expectations.json 里的 {cid} 找不到对应 case（语料被删了？）")

    print("")
    if failures:
        print(f"✗ {len(failures)} 处不一致 —— 指标口径或清洗逻辑发生了退化：")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"✓ 全部一致（{len(rows)} 个 case）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
