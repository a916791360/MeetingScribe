#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""速览/纪要 prompt 改造前后对比：同一模型、同一逐字稿、只换 prompt。"""
import json, subprocess, sys, os

SESS = "/Users/qingmeng/Library/Application Support/MeetingScribe/2026-09-13_210826_30CAD084/session.json"
KEY = open("/tmp/ms_ab/key.txt").read().strip()
ENDPOINT = "https://xtapi.site/v1/chat/completions"
MODEL = "deepseek-v4.1-flash"

d = json.load(open(SESS))
segs = d["transcriptSegments"]
transcript = "\n".join("[%.1f] %s" % (s["start"], s["text"]) for s in segs)
print("逐字稿长度 = %d 字符" % len(transcript))

SYSTEM = """你是一个严谨的中文会议整理助手。
你不负责猜测发言人、补齐听不清的内容或把讨论中的可能性写成结论。
只使用输入材料中明确出现的事实。"""

# ===== A. 现状 prompt（逐字复制自 SummaryEngine.swift）=====
PROMPT_A = """你正在整理一场中文工作会议。
只根据给定材料输出 JSON，不要输出 Markdown、解释或代码围栏。
不确定、语义不完整或只是提问的内容，一律不要写入决策和待办。
逐字稿不是让你改写；速览和纪要必须是理解后的归纳。
纪要正文只写讨论脉络、背景和过程，不要重复列出决策与待办。
决策和待办会由 App 单独展示；没有明确内容时输出空数组。
依据必须引用材料中的原句或原句片段，不要编造。
置信度是你对该条结论确实被材料支持的判断，保守填写 0 到 1。
时间戳使用材料中的秒数，无法确定就填 null。

输出结构：
{
  "overview": "一段能快速说明整场会议在讨论什么、形成了什么结果、下一步是什么的文字",
  "minutes": "会议纪要正文，只写讨论脉络、背景和过程，使用自然段和必要的小标题，不要重复决策与待办",
  "timeline": [
    {"start": 0, "end": 300, "summary": "这一阶段讨论了什么", "evidence": "依据", "confidence": 0.8}
  ],
  "decisions": [
    {"label": "明确结论", "evidence": "原文依据", "confidence": 0.8, "timestamp": 123.4}
  ],
  "actions": [
    {"label": "具体待办", "priority": "p1", "dueText": null, "evidence": "原文依据", "confidence": 0.8, "timestamp": 123.4}
  ],
  "confidence": 0.8
}

给定材料是带时间戳的会议逐字稿，请覆盖整场会议。

给定材料：
%s""" % transcript

# ===== B. 改造后的 prompt =====
PROMPT_B = """你正在为一场中文工作会议写「会后记录」。你的读者是没参会、但要立刻知道"结论是什么、我该做什么"的同事。

【材料说明】
给定材料是本机转写的中文逐字稿，可能含同音错字、断句错误和口语冗余（"然后呢""就是说"）。你在理解时自行纠正明显的同音误写（例如"固状系统"应为"故障系统"、"多摩泰"应为"多模态"、"公单"应为"工单"），但不要凭空补原文没有的事实。

【硬性要求】
1. 只输出 JSON，不要 Markdown、不要解释、不要代码围栏。
2. 速览（overview）不是主题清单，是一个"电梯汇报"：读者读完必须知道①这场会在解决什么问题 ②定了什么 ③下一步谁做什么。
3. 禁止使用这些空话动词：会上介绍了、讨论了、谈到了、提到了、围绕……展开、延伸到。写实质内容，不写"谁跟谁聊了某个话题"。
4. 必须写进内容里的东西：具体数字、版本号（1.1/1.2.0）、日期（周六/9月底）、人名、系统/模块名。原文有的一个都不能省。
5. 不确定、只是提问、只是可能性 → 不写进决策和待办；但如果是"待确认事项"就写进 openQuestions。
6. 每条结论和待办必须带 evidence（原文原句片段，不要编造）和 timestamp（材料里的秒数）。
7. 待办的 owner 只在原文明确出现负责人时填写，否则填 null。不要猜。

【输出结构】
{
  "headline": "一句话结论，不超过 30 字，说清这段会最终定了什么",
  "overviewBullets": [
    "一条要点，不超过 40 字；带时间锚，如 [12:30]"
  ],
  "minutes": "会议纪要正文，Markdown 小标题分节（每节标题写议题名，不写'第一议题'）。每节按'背景→讨论→结论'写实质内容，可以用有序列表。禁止写成过程叙述。可用 ## 标题。",
  "timeline": [{"start": 0, "end": 300, "summary": "这一阶段在谈什么、谈出了什么", "evidence": "原文依据", "confidence": 0.8}],
  "decisions": [{"label": "结论（必须是陈述句，不写'讨论了一下'）", "evidence": "原文依据", "confidence": 0.8, "timestamp": 123.4}],
  "actions": [{"label": "待办（动词开头 + 明确对象）", "owner": "负责人或 null", "priority": "p1", "dueText": "原文提到的截止时间或 null", "evidence": "原文依据", "confidence": 0.8, "timestamp": 123.4}],
  "openQuestions": [{"label": "原文提到但没定下来的事", "timestamp": 123.4}],
  "confidence": 0.8
}

【overviewBullets 怎么写】
- 3 到 6 条，按重要性排序，不按时间顺序复述。
- 每条是一个"信息"，不是一个"话题名"。反例："讨论了多模态"（错，这是话题名）。正例："[43:20] 多模态先做接口预留，移动端明确本期不做"（对，这是信息）。
- 决定、数字、日期、版本号优先放进前三条。

给定材料（带时间戳的中文会议逐字稿）：
%s""" % transcript


def call(prompt, label):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": prompt}],
        "temperature": 0.1,
        "max_tokens": 16000,
        "stream": False,
    }, ensure_ascii=False)
    with open("/tmp/ms_ab/req.json", "w") as f:
        f.write(body)
    cmd = ["curl", "-s", "--max-time", "600", "-X", "POST", ENDPOINT,
           "-H", "Content-Type: application/json",
           "-H", "Authorization: Bearer " + KEY,
           "--data-binary", "@/tmp/ms_ab/req.json"]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    try:
        j = json.loads(out)
    except Exception:
        print("[%s] 非 JSON 回包：%s" % (label, out[:400])); return None
    if "choices" not in j:
        print("[%s] 错误回包：%s" % (label, json.dumps(j, ensure_ascii=False)[:400])); return None
    ch = j["choices"][0]
    usage = j.get("usage", {})
    content = (ch.get("message") or {}).get("content") or ""
    print("  [%s] finish=%s usage=%s 正文 %d 字符" % (label, ch.get("finish_reason"), usage, len(content)))
    return content


print("\n调用 A（现状 prompt）...")
a = call(PROMPT_A, "现在")
open("/tmp/ms_ab/outA.txt", "w").write(a or "")

print("调用 B（改造 prompt）...")
b = call(PROMPT_B, "改造后")
open("/tmp/ms_ab/outB.txt", "w").write(b or "")

def show(title, txt):
    print("\n" + "=" * 96)
    print(title)
    print("=" * 96)
    if not txt:
        print("(空)")
        return
    t = txt.replace("```json", "").replace("```", "").strip()
    i, j = t.find("{"), t.rfind("}")
    if i >= 0 and j > i:
        t = t[i:j+1]
    try:
        p = json.loads(t)
    except Exception as e:
        print("(JSON 解析失败 %s)\n%s" % (e, t[:2000])); return
    print("【一句话结论】", p.get("headline", "(无)"))
    bl = p.get("overviewBullets") or []
    if bl:
        print("【速览要点】")
        for x in bl:
            print("  •", x)
    elif p.get("overview"):
        print("【速览】", p["overview"])
    print("\n【纪要正文 — 前 1200 字】")
    print((p.get("minutes") or "(空)")[:1200])
    print("\n【决策】%d 条 / 【待办】%d 条 / 【待确认】%d 条" %
          (len(p.get("decisions") or []), len(p.get("actions") or []), len(p.get("openQuestions") or [])))
    for x in (p.get("actions") or [])[:12]:
        print("  - [%s] %s  owner=%s due=%s" % (x.get("priority"), x.get("label"), x.get("owner"), x.get("dueText")))

show("A. 现状 prompt 的输出", a)
show("B. 改造后 prompt 的输出", b)
