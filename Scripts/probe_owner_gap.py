#!/usr/bin/env python3
"""诊断：`actionsWithOwnerRatio` 低，是**材料缺口**还是**抽取缺陷**？

为什么需要这个探针：§6 把「待办带 owner 占比 <30%」作为 P2-2a 双声道录音的触发条件。
但同一条低指标有两种病因，治法完全相反：

| 病因 | 证据 | 该做什么 | 做错会怎样 |
|---|---|---|---|
| 材料缺口 | 逐字稿里几乎没人说「谁负责」 | **P2-2a 双声道**（把「你」变成可判定） | — |
| 抽取缺陷 | 逐字稿明写了负责人，产出却是「未指定」 | 修抽取 prompt | 上双声道＝修错地方 |

**这个分辨步骤不能省。** 本项目已有 7 次「指标口径/适用性错，把人带去修没坏的东西」的同型事故
（见 `~/.workbuddy/skills/llm-content-quality-eval/references/metric-pitfalls.md`）。

反过来也要说清楚：若材料里**根本没有**责任人，那就**不能**靠改 prompt 去凑这个指标 ——
那只会让模型编出责任人，把「缺信息」换成「幻觉」。缺信息只能从材料侧补。

口径（**粗口径，只判量级，不做精算**）：
  命中段 = 含指派/承接词 且 长度 > 8 的段。裸词匹配**会高估**（「负责」也可能出现在
  「这个我不负责」这种否定句里），所以它是**上限估计**；绝对值不能跨会议时长套用，
  这里只用来比较「材料侧」与「产出侧」两个比例。
  `你` 指代段 = 用第二人称指责任人、且没点名 —— **这些只有区分说话人才能落地**，
  是双声道录音最直接的收益来源。

用法：
  python3 Scripts/probe_owner_gap.py                     # 真实语料全部 case
  python3 Scripts/probe_owner_gap.py --cases long-full   # 只看一场
  python3 Scripts/probe_owner_gap.py --json              # 机器可读，供前后对比
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_CORPUS = REPO / "docs/verification/quality"

ASSIGN_WORDS = ["负责", "安排", "跟进", "对接", "来做", "来搞", "牵头", "落实",
                "推进", "盯", "出个", "出一", "写一", "同步给", "确认一下"]
ROLE_WORDS = ["研发", "产品", "测试", "客服", "财务", "运营", "设计",
              "前端", "后端", "销售", "工程", "售后", "采购"]
# 「你/您」指代责任人：只有区分说话人之后才知道是谁
SECOND_PERSON = ["你负责", "你来", "你做", "你先", "你这边", "你们",
                 "您负责", "您来", "您这边", "哥们你", "你自己"]
MAX_LISTED = 22
# §6 里「待办带 owner 占比」的那条线。写在这里是为了让「材料侧天花板 < 线」这件事
# 一眼可见 —— 天花板低于线时，**任何抽取侧的努力都不可能达标**。
CEILING_THRESHOLD = 0.30


def analyze(case: dict, run: dict) -> dict:
    segs = case.get("segments") or []
    acts = ((run.get("analysis") or {}).get("actions")) or []

    hits = [(int(s.get("start", 0)), s.get("text", "")) for s in segs
            if len(s.get("text", "")) > 8 and any(w in s["text"] for w in ASSIGN_WORDS)]
    named = [h for h in hits
             if (any(r in h[1] for r in ROLE_WORDS)
                 or re.search(r"[\u4e00-\u9fa5]{1,2}(总|哥|姐|老师)", h[1])
                 or re.search(r"[A-Z]{2,5}", h[1]))]
    # ⚠️ 交集才是「只有区分说话人才能救」的那部分：既用「你」，又没点名。
    second = [h for h in hits
              if any(w in h[1] for w in SECOND_PERSON)
              and h not in named]
    filled = [x for x in acts if x.get("owner")]

    return {
        "caseId": case.get("caseId"),
        "durationMinutes": round((case.get("durationSeconds") or 0) / 60, 1),
        "segments": len(segs),
        "assignSegments": len(hits),
        "assignShare": round(len(hits) / max(1, len(segs)), 4),
        "namedAssignSegments": len(named),
        "namedShare": round(len(named) / max(1, len(hits)), 4),
        "secondPersonOnly": len(second),
        "actions": len(acts),
        "actionsWithOwner": len(filled),
        "ownerFillRate": round(len(filled) / max(1, len(acts)), 4) if acts else None,
        "_hits": hits, "_named": named, "_second": second,
        "_owners": [x.get("owner") for x in acts],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=None)
    ap.add_argument("--cases", default="", help="逗号分隔的 caseId")
    ap.add_argument("--json", action="store_true", help="只输出 JSON，供前后对比")
    ap.add_argument("--list-hits", action="store_true", help="打印命中原话（人工复核用）")
    args = ap.parse_args()

    corpus = pathlib.Path(args.corpus) if args.corpus else DEFAULT_CORPUS
    want = {c.strip() for c in args.cases.split(",") if c.strip()}

    out = []
    for case_path in sorted((corpus / "cases").glob("*.json")):
        case = json.loads(case_path.read_text(encoding="utf-8"))
        if want and case.get("caseId") not in want:
            continue
        run_path = corpus / "runs" / case_path.name
        if not run_path.exists():
            continue
        run = json.loads(run_path.read_text(encoding="utf-8"))
        if case.get("expect") == "emptyState":
            continue  # 空态场本来就不该有待办，不参与这个诊断
        out.append(analyze(case, run))

    if not out:
        print("没有可诊断的 case。", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps([{k: v for k, v in r.items() if not k.startswith("_")}
                          for r in out], ensure_ascii=False, indent=1))
        return 0

    print("# owner 缺口诊断（材料侧 vs 产出侧）\n")
    print("| case | 时长 | 段数 | 指派段 | 占段数 | 其中点名 | 点名/指派 | **只靠「你」** |"
          " 待办 | owner 非空 | **抽中率** |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for r in out:
        print(f"| {r['caseId']} | {r['durationMinutes']}min | {r['segments']} |"
              f" {r['assignSegments']} | {r['assignShare'] * 100:.1f}% |"
              f" {r['namedAssignSegments']} | {r['namedShare'] * 100:.0f}% |"
              f" {r['secondPersonOnly']} | {r['actions']} | {r['actionsWithOwner']} |"
              f" **{(r['ownerFillRate'] or 0) * 100:.1f}%** |")
    print()

    tot_actions = sum(r["actions"] for r in out)
    tot_filled = sum(r["actionsWithOwner"] for r in out)
    tot_assign = sum(r["assignSegments"] for r in out)
    tot_named = sum(r["namedAssignSegments"] for r in out)
    tot_second = sum(r["secondPersonOnly"] for r in out)
    tot_segs = sum(r["segments"] for r in out)
    material = tot_named / max(1, tot_actions)   # 材料侧天花板（分母与指标同口径）
    product = tot_filled / max(1, tot_actions)
    print(f"合计：段 {tot_segs}，指派段 {tot_assign}（{tot_assign / max(1, tot_segs) * 100:.1f}%），"
          f"其中点名 {tot_named}，只靠「你」{tot_second}；"
          f"待办 {tot_actions}，owner 非空 {tot_filled} = {product * 100:.1f}%")
    print(f"      **材料侧天花板**（点名指派 {tot_named} 条 ÷ 待办 {tot_actions}）"
          f"= **{material * 100:.1f}%**，产出侧实得 {product * 100:.1f}%"
          f"（已抽到天花板的 {product / max(1e-9, material) * 100:.0f}%）")
    print()

    print("## 判定\n")
    if material < CEILING_THRESHOLD:
        print(f"→ **材料缺口**：逐字稿里「点名的指派」就只有 **{material * 100:.1f}%**，"
              f"**低于 §6 那条 {CEILING_THRESHOLD:.0%} 的线** ——")
        print("  也就是说**再完美的抽取也到不了线**。这时候改 prompt 只会让模型编出责任人，"
              "把「缺信息」换成「幻觉」。")
        print("  只有两条路：① 从**材料侧**补（→ **P2-2a 双声道录音**）；"
              "② 承认这条指标对**本类会议**不适用。")
        if product >= material * 0.7:
            print(f"  顺带排除抽取缺陷：产出侧已抽到 {product * 100:.1f}%、天花板 {material * 100:.1f}%，"
                  f"**通过率 {product / max(1e-9, material) * 100:.0f}%，抽取链路是好的，别动它**。")
    elif tot_named / max(1, tot_assign) >= 0.6 and product < material * 0.7:
        print(f"→ **抽取缺陷嫌疑**：材料侧点名率 {tot_named / max(1, tot_assign) * 100:.0f}% 不低，"
              f"但产出只抽到 {product * 100:.1f}%（天花板的 {product / max(1e-9, material) * 100:.0f}%）——")
        print("  先查抽取 prompt / 结构化字段，别急着上双声道。")
    else:
        print("→ 证据不足以判。抽 3~5 条待办，人工回到逐字稿确认「有没有明写谁负责」再定。")

    for r in out:
        if not args.list_hits:
            continue
        print(f"\n### {r['caseId']} 命中原话")
        for t, txt in r["_hits"][:MAX_LISTED]:
            mark = "★点名" if (t, txt) in r["_named"] else (
                "☆只有你" if (t, txt) in r["_second"] else "  ")
            print(f"  {mark} [{t:>5}s] {txt[:100]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
