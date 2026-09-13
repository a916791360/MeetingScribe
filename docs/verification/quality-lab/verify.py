#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证两条修复路线：
  B1: 单次调用 + 更高预算(32k) —— 看改造 prompt 能不能完整产出
  B2: 拆成两次调用（速览一次 / 纪要一次）—— 每次输出更小，推理链更短
"""
import json, subprocess, sys

SESS = "/Users/qingmeng/Library/Application Support/MeetingScribe/2026-09-13_210826_30CAD084/session.json"
KEY = open("/tmp/ms_ab/key.txt").read().strip()
ENDPOINT = "https://xtapi.site/v1/chat/completions"
MODEL = "deepseek-v4.1-flash"

d = json.load(open(SESS))
segs = d["transcriptSegments"]
raw = "\n".join("[%.1f] %s" % (s["start"], s["text"]) for s in segs)

# 用后处理后的逐字稿（合并碎片 + 纠错），模拟"改进后"的输入
sys.path.insert(0, "/tmp/ms_ab")
import importlib.util
spec = importlib.util.spec_from_file_location("pp", "/tmp/ms_ab/postprocess.py")

def build_clean_transcript():
    GLOSSARY = [("固状系统","故障系统"),("固状","故障"),("多摩泰","多模态"),("公单中心","工单中心"),
                ("公单","工单"),("收货问答","售后问答"),("炫贵","炫酷"),("前张","前端"),
                ("诊断专要","诊断摘要"),("重够","重构"),("收视频","搜视频")]
    import re
    def fix(t):
        for w,r in GLOSSARY: t = t.replace(w,r)
        return t
    def collapse(t):
        prev=None
        while prev!=t:
            prev=t
            t = re.sub(r"([\u4e00-\u9fa5A-Za-z0-9]{2,8})(?:\s*\1){2,}", r"\1", t)
        return t
    SENT="。？！?!"
    def merge(arr,min_chars=40,max_chars=120,pause=1.6):
        out=[];cur=None
        for s in arr:
            t=s["text"].strip()
            if not t: continue
            if cur is None:
                cur={"start":s["start"],"end":s["end"],"text":t};continue
            gap=s["start"]-cur["end"]
            if (cur["text"][-1] in SENT and len(cur["text"])>=min_chars) or gap>pause or len(cur["text"])+len(t)>max_chars:
                out.append(cur);cur={"start":s["start"],"end":s["end"],"text":t};continue
            cur["text"]+=t;cur["end"]=s["end"]
        if cur: out.append(cur)
        return out
    ok=[s for s in segs if s["confidence"]>=0.30 or len(s["text"])>=8]
    ok=[{**s,"text":collapse(fix(s["text"]))} for s in ok]
    return "\n".join("[%.1f] %s" % (s["start"], s["text"]) for s in merge(ok))

CLEAN = build_clean_transcript()
print("原始逐字稿 %d 字符 / 清洗后 %d 字符" % (len(raw), len(CLEAN)))

SYSTEM = """你是一个严谨的中文会议整理助手。
不猜测发言人，不补齐听不清的内容，不把讨论中的可能性写成结论。
逐字稿由本机转写，含同音错字与口语冗余；纠正明显的同音误写（如"固状系统"→"故障系统"、"多摩泰"→"多模态"、"公单"→"工单"），但不得凭空补充原文没有的事实。"""

# ---------- B1: 单次 + 32k ----------
P_B1 = """你正在为一场中文工作会议写会后记录。读者是没参会、但要立刻知道"结论是什么、我该做什么"的同事。

硬性要求：
1. 只输出 JSON，不要 Markdown 代码围栏、不要解释。
2. 速览不是主题清单，是电梯汇报：读完必须知道①在解决什么问题 ②定了什么 ③下一步谁做什么。
3. 禁止空话动词：会上介绍了、讨论了、谈到了、提到、围绕……展开、延伸到。写实质内容。
4. 必须保留原文里的具体数字、版本号、日期、人名、系统名，一个都不能省。
5. 只是提问或可能性 → 不写进决策待办；没定下来的写进 openQuestions。
6. 每条带 evidence（原文片段）与 timestamp（秒）。
7. 待办 owner 只在原文明确出现负责人时填写，否则 null。

输出：
{
  "headline": "不超过30字的一句话结论",
  "overviewBullets": ["每条不超过40字，前三条优先放决定/数字/日期/版本号，带时间锚如 [12:30]"],
  "minutes": "纪要正文。用 ## 议题名 分节，每节按背景→讨论→结论写实质内容。禁止过程叙述。",
  "timeline": [{"start":0,"end":300,"summary":"这阶段谈什么、谈出了什么","evidence":"原文","confidence":0.8}],
  "decisions": [{"label":"陈述句结论","evidence":"原文","confidence":0.8,"timestamp":12.3}],
  "actions": [{"label":"动词开头的待办","owner":null,"priority":"p1","dueText":null,"evidence":"原文","confidence":0.8,"timestamp":12.3}],
  "openQuestions": [{"label":"提到但没定的事","timestamp":12.3}],
  "confidence": 0.8
}

材料：
""" + CLEAN

# ---------- B2a: 只要速览 ----------
P_B2a = """给你一场中文工作会议的逐字稿。只做「速览」，不要写纪要。

要求：
- 只输出 JSON，无代码围栏。
- 速览是电梯汇报，不是话题清单。读者要立刻知道：在解决什么问题、定了什么、下一步做什么。
- 禁止空话动词：会上介绍了、讨论了、谈到了、提到。写实质内容。
- 具体数字、版本号、日期、人名、系统名一个都不能省。
- 3~6 条要点，按重要性排序（不按时间顺序）；反例"讨论了多模态"（话题名），正例"[43:20] 多模态先做接口预留，移动端本期不做"（信息）。

输出：
{
  "headline": "不超过30字的一句话结论",
  "overviewBullets": ["…", "…"],
  "timeline": [{"start":0,"end":300,"summary":"…","evidence":"原文","confidence":0.8}],
  "decisions": [{"label":"陈述句结论","evidence":"原文","confidence":0.8,"timestamp":12.3}],
  "actions": [{"label":"动词开头的待办","owner":null,"priority":"p1","dueText":null,"evidence":"原文","confidence":0.8,"timestamp":12.3}],
  "openQuestions": [{"label":"提到但没定的事","timestamp":12.3}],
  "confidence": 0.8
}

材料：
""" + CLEAN

# ---------- B2b: 只要纪要 ----------
P_B2b = """给你一场中文工作会议的逐字稿。只写「会议纪要正文」，不要重复决策和待办（它们会单独展示）。

要求：
- 只输出 JSON，外层键只有 minutes。
- 用 ## 议题名 分节。每节按「背景 → 讨论要点 → 结论」写，可以用有序列表。
- 写的是**实质性内容**（谁提了什么方案、数字是多少、为什么否掉），不是过程叙述。
- 绝对禁止这些句式：会上介绍了、会上讨论了、谈到了、提到了、围绕……展开、延伸到、中段主要围绕。
- 原文里的数字、版本号、日期、人名、系统名必须写进去。
- 篇幅要够：这场会议 45 分钟，纪要正文不少于 1200 字。
- 每节标题后用 [mm:ss] 标注该节起始时间。

输出：
{"minutes": "…"}

材料：
""" + CLEAN


def call(prompt, label, budget):
    body = json.dumps({"model": MODEL,
                       "messages": [{"role":"system","content":SYSTEM},
                                    {"role":"user","content":prompt}],
                       "temperature": 0.1, "max_tokens": budget, "stream": False},
                      ensure_ascii=False)
    open("/tmp/ms_ab/req2.json","w").write(body)
    out = subprocess.run(["curl","-s","--max-time","900","-X","POST",ENDPOINT,
                          "-H","Content-Type: application/json",
                          "-H","Authorization: Bearer "+KEY,
                          "--data-binary","@/tmp/ms_ab/req2.json"],
                         capture_output=True, text=True).stdout
    try: j = json.loads(out)
    except Exception:
        print("[%s] 非 JSON: %s" % (label, out[:300])); return None
    if "choices" not in j:
        print("[%s] 错误: %s" % (label, json.dumps(j, ensure_ascii=False)[:300])); return None
    ch = j["choices"][0]; u = j.get("usage", {})
    det = (u.get("completion_tokens_details") or {})
    c = (ch.get("message") or {}).get("content") or ""
    print("  [%s] finish=%s 正文=%d字符 思考token=%s/总%s" %
          (label, ch.get("finish_reason"), len(c), det.get("reasoning_tokens"), u.get("completion_tokens")))
    return c

print("\n=== B1 单次调用，预算 32000 ===")
b1 = call(P_B1, "B1", 32000)
open("/tmp/ms_ab/outB1.txt","w").write(b1 or "")

print("=== B2a 只要速览，预算 16000 ===")
b2a = call(P_B2a, "B2a", 16000)
open("/tmp/ms_ab/outB2a.txt","w").write(b2a or "")

print("=== B2b 只要纪要，预算 16000 ===")
b2b = call(P_B2b, "B2b", 16000)
open("/tmp/ms_ab/outB2b.txt","w").write(b2b or "")

def parse(t):
    if not t: return None
    t = t.replace("```json","").replace("```","").strip()
    i,j = t.find("{"), t.rfind("}")
    if i>=0 and j>i: t = t[i:j+1]
    try: return json.loads(t)
    except Exception as e:
        print("  (解析失败: %s)" % e); return None

print("\n" + "="*96); print("B1 输出"); print("="*96)
p = parse(b1)
if p:
    print("【结论】", p.get("headline"))
    for x in (p.get("overviewBullets") or []): print("  •", x)
    print("\n【纪要前 900 字】\n", (p.get("minutes") or "")[:900])
    print("\n决策 %d / 待办 %d / 待确认 %d" % (len(p.get("decisions") or []), len(p.get("actions") or []), len(p.get("openQuestions") or [])))
else:
    print("(空或不可解析)")

print("\n" + "="*96); print("B2 两段式输出"); print("="*96)
pa, pb = parse(b2a), parse(b2b)
if pa:
    print("【结论】", pa.get("headline"))
    for x in (pa.get("overviewBullets") or []): print("  •", x)
    print("\n决策 %d / 待办 %d / 待确认 %d" % (len(pa.get("decisions") or []), len(pa.get("actions") or []), len(pa.get("openQuestions") or [])))
    print("【待办】")
    for x in (pa.get("actions") or []):
        print("  - [%s] %s owner=%s due=%s" % (x.get("priority"), x.get("label"), x.get("owner"), x.get("dueText")))
if pb:
    m = pb.get("minutes") or ""
    print("\n【纪要】%d 字，前 1400 字：\n%s" % (len(m), m[:1400]))
