#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对比 whisper 三组参数在同一段音频上的转写结果。"""
import json, re, sys, statistics

ROOT = "/Users/qingmeng/Library/Application Support/MeetingScribe/2026-09-13_210826_30CAD084"
RUNS = {
    "A 现状": ROOT + "/chunks/chunk-0001.json",
    "B 术语+去非语音": "/tmp/ms_ab/runB.json",
    "C VAD+术语+去非语音": "/tmp/ms_ab/runC.json",
}
LIMIT = 600  # owned segment 上限（秒），与 App 的 coreEnd 一致

# 逐字稿里被听错的专有名词（左：错，右：对）
ERROR_TERMS = [
    ("固状", "故障"), ("多摩泰", "多模态"), ("公单", "工单"),
    ("收货问答", "售后问答"), ("炫贵", "炫酷"), ("前张", "前端"),
    ("专要", "摘要"), ("重够", "重构"), ("收视频", "搜视频"),
    ("缩这个", "说这个"), ("同弟", "同样"), ("素质", "资料"),
    ("伊勒曲比亚", "（公司名待定）"),
]
# 噪声/幻觉片段（无实义的高频短句）
FILLER = ["项目卡 项目卡", "也就是会出气了", "嗯 嗯 嗯", "好 好 好"]

def load(path):
    d = json.load(open(path))
    segs = []
    for s in d["transcription"]:
        st = float(s["offsets"]["from"]) / 1000
        en = float(s["offsets"]["to"]) / 1000
        if st >= LIMIT:
            continue
        txt = s["text"].strip()
        if not txt:
            continue
        toks = s.get("tokens") or []
        ps = [t["p"] for t in toks if t.get("p") is not None]
        conf = sum(ps) / len(ps) if ps else 0.5
        segs.append({"start": st, "end": en, "text": txt, "conf": conf})
    segs.sort(key=lambda x: x["start"])
    return segs

def punct_count(segs):
    return sum(1 for s in segs if re.search(r"[，。？！、；：,.?!]", s["text"]))

def dup_runs(text):
    """统计连续重复的 2~4 字片段出现的最大次数（幻觉复读检测）。"""
    best = 0
    for n in (2, 3, 4):
        for m in re.finditer(r"(.{%d})\1+" % n, text):
            best = max(best, len(m.group(0)) // n)
    return best

rows = {}
for name, path in RUNS.items():
    try:
        segs = load(path)
    except Exception as e:
        print("跳过 %s: %s" % (name, e)); continue
    text = "".join(s["text"] for s in segs)
    lens = [len(s["text"]) for s in segs]
    rows[name] = {
        "段数": len(segs),
        "总字数": len(text),
        "均字/段": statistics.mean(lens) if lens else 0,
        "中位字/段": statistics.median(lens) if lens else 0,
        "均时长s": statistics.mean(s["end"] - s["start"] for s in segs) if segs else 0,
        "有标点段占比": 100 * punct_count(segs) / len(segs) if segs else 0,
        "低置信段(<0.4)": sum(1 for s in segs if s["conf"] < 0.4),
        "均置信度": statistics.mean(s["conf"] for s in segs) if segs else 0,
        "最大复读": dup_runs(text),
        "text": text,
    }

print("=" * 100)
print("同一段音频（0~600s，44.6 分钟会议的前 10 分钟）三组参数对比")
print("=" * 100)
keys = ["段数", "总字数", "均字/段", "中位字/段", "均时长s", "有标点段占比", "低置信段(<0.4)", "均置信度", "最大复读"]
hdr = "指标".ljust(16) + "".join(k.ljust(20) for k in rows)
print(hdr)
for k in keys:
    line = k.ljust(16)
    for name in rows:
        v = rows[name][k]
        line += (("%.2f" % v) if isinstance(v, float) else str(v)).ljust(20)
    print(line)

print()
print("=" * 100)
print("专有名词命中情况（在 0~600s 逐字稿里出现的次数）")
print("=" * 100)
print("错词 → 正词".ljust(30) + "".join(n.ljust(20) for n in rows))
for wrong, right in ERROR_TERMS:
    line = ("%s → %s" % (wrong, right)).ljust(30)
    for name in rows:
        line += str(rows[name]["text"].count(wrong)).ljust(20)
    print(line)

print()
print("=" * 100)
print("幻觉复读片段出现次数")
print("=" * 100)
print("片段".ljust(30) + "".join(n.ljust(20) for n in rows))
for f in FILLER:
    line = f.ljust(30)
    for name in rows:
        line += str(rows[name]["text"].count(f)).ljust(20)
    print(line)

print()
print("=" * 100)
print("开头 20 段原文对照（第 0~100 秒）")
print("=" * 100)
for name in rows:
    print("\n---------- %s ----------" % name)
    segs = load(RUNS[name])
    for s in segs:
        if s["start"] > 100:
            break
        print("[%6.1f] %s" % (s["start"], s["text"]))
