#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""逐字稿后处理演示：①按句合并碎片 ②术语表纠错 ③低置信/复读清理。
不调用任何模型，纯确定性处理，可直接搬进 Model 层。"""
import json, re

SESS = "/Users/qingmeng/Library/Application Support/MeetingScribe/2026-09-13_210826_30CAD084/session.json"
d = json.load(open(SESS))
segs = d["transcriptSegments"]

# ---------- ① 术语表纠错 ----------
GLOSSARY = [
    ("固状系统", "故障系统"), ("固状", "故障"), ("多摩泰", "多模态"),
    ("公单中心", "工单中心"), ("公单", "工单"), ("收货问答", "售后问答"),
    ("炫贵", "炫酷"), ("前张", "前端"), ("诊断专要", "诊断摘要"),
    ("重够", "重构"), ("收视频", "搜视频"), ("伊勒曲比亚", "（公司名待确认）"),
]

def fix_terms(text):
    for wrong, right in GLOSSARY:
        text = text.replace(wrong, right)
    return text

# ---------- ② 复读清理 ----------
def collapse_repeats(text):
    """把「项目卡 项目卡 项目卡 项目卡」这类复读压成一次。"""
    prev = None
    while prev != text:
        prev = text
        text = re.sub(r"([\u4e00-\u9fa5A-Za-z0-9]{2,8})(?:\s*\1){2,}", r"\1", text)
    return text

# ---------- ③ 低置信垃圾段丢弃 ----------
def drop_low_conf(segs, th=0.30):
    return [s for s in segs if s["confidence"] >= th or len(s["text"]) >= 8]

# ---------- ④ 按句合并碎片 ----------
SENT_END = "。？！?!"
def merge_segments(segs, min_chars=40, max_chars=120, pause=1.6):
    """把 whisper 的碎片段合并成"一句/一段话"：
    合并条件（任一即断）：
      - 上一段已以句末标点结尾
      - 两段间隔 > pause 秒（说话人换气/切换）
      - 累计长度 >= max_chars
      - 下一段以句末标点结尾且累计已 >= min_chars
    """
    out = []
    cur = None
    for s in segs:
        t = s["text"].strip()
        if not t:
            continue
        if cur is None:
            cur = {"start": s["start"], "end": s["end"], "text": t,
                   "conf": [s["confidence"]]}
            continue
        gap = s["start"] - cur["end"]
        if cur["text"][-1] in SENT_END and len(cur["text"]) >= min_chars:
            out.append(cur); cur = {"start": s["start"], "end": s["end"], "text": t, "conf": [s["confidence"]]}
            continue
        if gap > pause or len(cur["text"]) + len(t) > max_chars:
            out.append(cur); cur = {"start": s["start"], "end": s["end"], "text": t, "conf": [s["confidence"]]}
            continue
        # 直接焊接；中文句内不需要空格
        cur["text"] += t
        cur["end"] = s["end"]
        cur["conf"].append(s["confidence"])
    if cur:
        out.append(cur)
    for c in out:
        c["confidence"] = sum(c["conf"]) / len(c["conf"])
        del c["conf"]
    return out

# ---------- 应用 ----------
cleaned = []
for s in drop_low_conf(segs):
    cleaned.append({**s, "text": collapse_repeats(fix_terms(s["text"]))})

merged = merge_segments(cleaned)

print("=" * 96)
print("逐字稿后处理效果（整场 44.6 分钟会议）")
print("=" * 96)
print("%-26s %8s %10s %12s %10s" % ("阶段", "段数", "总字数", "均字/段", "中位字/段"))
import statistics
def stat(label, arr):
    lens = [len(x["text"]) for x in arr]
    print("%-26s %8d %10d %12.1f %10.1f" % (label, len(arr), sum(lens), statistics.mean(lens), statistics.median(lens)))
stat("① 原始（现状）", segs)
stat("② 术语纠错+复读清理+去低置信", cleaned)
stat("③ 再按句合并", merged)

print()
print("=" * 96)
print("术语表纠错命中统计（整场）")
print("=" * 96)
raw = "".join(s["text"] for s in segs)
for wrong, right in GLOSSARY:
    n = raw.count(wrong)
    if n:
        print("  %-12s → %-14s  %d 处" % (wrong, right, n))

print()
print("=" * 96)
print("合并前后对照样本（第 5~55 秒）")
print("=" * 96)
print("---------- 现状（whisper 原始分段）----------")
for s in segs[3:14]:
    print("[%6.1f-%6.1f] %s" % (s["start"], s["end"], s["text"]))
print()
print("---------- 合并 + 纠错后 ----------")
for s in merged:
    if 5 <= s["start"] <= 60:
        print("[%6.1f-%6.1f] %s" % (s["start"], s["end"], s["text"]))
