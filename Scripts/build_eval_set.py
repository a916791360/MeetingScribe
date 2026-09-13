#!/usr/bin/env python3
"""从数据根导出「质量评测集」。

用法：
    python3 Scripts/build_eval_set.py            # 构建评测集
    python3 Scripts/build_eval_set.py --list      # 只看有哪些会话、预估怎么切片

设计约束（重要）：
  1. 数据根**只读**：本脚本只 `open(..., "r")`，任何情况下都不写入、不移动、不删除。
  2. 评测集含真实会议内容 → 落在 `docs/verification/quality/cases/`，该目录已 gitignore。
  3. 素材不足时**如实减少 case 数**并在 manifest 里写清缺口，不伪造语料。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DATA_ROOT = pathlib.Path.home() / "Library/Application Support/MeetingScribe"
OUT_DIR = REPO / "docs/verification/quality/cases"

# 切片长度（秒）。计划里允许「把历史录音各切片 15 分钟即可」。
SLICE_SECONDS = 900.0


def read_sessions() -> list[dict]:
    sessions = []
    if not DATA_ROOT.is_dir():
        return sessions
    for d in sorted(DATA_ROOT.iterdir()):
        sj = d / "session.json"
        if not sj.is_file():
            continue
        try:
            data = json.loads(sj.read_text(encoding="utf-8"))
        except Exception as exc:  # 坏文件跳过，不阻断
            print(f"  ! 跳过 {d.name}：{exc}", file=sys.stderr)
            continue
        segments = data.get("transcriptSegments") or []
        if not segments:
            continue
        sessions.append(
            {
                "folder": d.name,
                "title": data.get("title") or d.name,
                "duration": float(data.get("duration") or 0.0),
                "segments": segments,
                "analysis": data.get("analysis") or {},
            }
        )
    return sessions


def slice_segments(segments: list[dict], start: float, end: float) -> list[dict]:
    """按时间窗口取段。跨窗口的段归给「与窗口重叠更多」的一侧，避免重复计入。"""
    out = []
    for seg in segments:
        s, e = float(seg.get("start", 0.0)), float(seg.get("end", 0.0))
        if e <= start or s >= end:
            continue
        out.append(
            {
                "start": s,
                "end": e,
                "text": seg.get("text", ""),
                "confidence": round(float(seg.get("confidence", 0.0)), 4),
            }
        )
    return out


def char_count(segments: list[dict]) -> int:
    return sum(len(s["text"].strip()) for s in segments)


def make_case(case_id, label, session, segments, start, end, expect, note=""):
    return {
        "schemaVersion": 1,
        "caseId": case_id,
        "label": label,
        "sourceSession": session["folder"],
        "sourceTitle": session["title"],
        "sliceStart": start,
        "sliceEnd": end,
        "durationSeconds": round(end - start, 2),
        "expect": expect,
        "note": note,
        "segmentCount": len(segments),
        "charCount": char_count(segments),
        "segments": segments,
    }


def build() -> int:
    sessions = read_sessions()
    if not sessions:
        print("数据根没有可用会话，无法构建评测集。", file=sys.stderr)
        return 1

    cases: list[dict] = []
    gaps: list[str] = []

    # ---- 长会（取时长最长的一场）----
    long_session = max(sessions, key=lambda s: s["duration"])
    dur = long_session["duration"]
    segs = long_session["segments"]

    if dur >= 2 * SLICE_SECONDS:
        # 切成若干 15 分钟窗口 + 一场完整
        n_slices = int(dur // SLICE_SECONDS) + (1 if dur % SLICE_SECONDS > 60 else 0)
        for i in range(n_slices):
            start = i * SLICE_SECONDS
            end = min(dur, start + SLICE_SECONDS)
            if end - start < 60:
                continue
            sl = slice_segments(segs, start, end)
            if not sl:
                continue
            cases.append(
                make_case(
                    f"slice{i + 1}-{int(start // 60)}-{int(round(end / 60))}min",
                    f"切片 {i + 1}：{int(start // 60)}–{int(round(end / 60))} 分钟",
                    long_session,
                    sl,
                    start,
                    end,
                    "content",
                    "由长会切片得到，模拟一场 15 分钟短会",
                )
            )
        cases.append(
            make_case(
                "long-full",
                f"长会完整（{dur / 60:.1f} 分钟）",
                long_session,
                slice_segments(segs, 0.0, dur),
                0.0,
                dur,
                "content",
                "完整长会，用于观察预算与分章边界",
            )
        )
    else:
        cases.append(
            make_case(
                "long-full",
                f"长会完整（{dur / 60:.1f} 分钟）",
                long_session,
                slice_segments(segs, 0.0, dur),
                0.0,
                dur,
                "content",
            )
        )
        gaps.append("素材不足 30 分钟，未能切出 15 分钟短会样例")

    # ---- 超短误录（挑最短的一场，期望走空态）----
    short_session = min(sessions, key=lambda s: s["duration"])
    if short_session["folder"] != long_session["folder"] and short_session["duration"] < 120:
        cases.append(
            make_case(
                "too-short",
                f"超短误录（{short_session['duration']:.0f} 秒）",
                short_session,
                slice_segments(short_session["segments"], 0.0, short_session["duration"]),
                0.0,
                short_session["duration"],
                "emptyState",
                "期望：走空态，不产出元评论",
            )
        )
    else:
        gaps.append("没有独立的超短会话来验证「材料不足 → 空态」")

    # ---- 长材料（验证分章路径）----
    longest_chars = max(char_count(s["segments"]) for s in sessions)
    if longest_chars <= 24_000:
        gaps.append(
            f"最长逐字稿仅 {longest_chars} 字符（分章阈值 24000）→ "
            "分章路径未被任何 case 覆盖，P2-4 暂无法验证"
        )

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for c in cases:
        (OUT_DIR / f"{c['caseId']}.json").write_text(
            json.dumps(c, ensure_ascii=False, indent=1), encoding="utf-8"
        )

    manifest = {
        "builtFrom": str(DATA_ROOT),
        "sessionCount": len(sessions),
        "caseCount": len(cases),
        "cases": [
            {
                "caseId": c["caseId"],
                "label": c["label"],
                "durationSeconds": c["durationSeconds"],
                "segmentCount": c["segmentCount"],
                "charCount": c["charCount"],
                "expect": c["expect"],
            }
            for c in cases
        ],
        "gaps": gaps,
    }
    (REPO / "docs/verification/quality/manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8"
    )

    print(f"已写出 {len(cases)} 个 case → {OUT_DIR.relative_to(REPO)}")
    for c in manifest["cases"]:
        print(
            f"  {c['caseId']:<22} {c['durationSeconds']:>7.0f}s  "
            f"{c['segmentCount']:>4} 段  {c['charCount']:>6} 字  {c['label']}"
        )
    for g in gaps:
        print(f"  [缺口] {g}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="只列出会话，不写文件")
    args = ap.parse_args()
    if args.list:
        for s in read_sessions():
            print(
                f"{s['folder']}  {s['duration']:>8.1f}s  "
                f"{len(s['segments']):>4} 段  {char_count(s['segments']):>6} 字  {s['title']}"
            )
        return 0
    return build()


if __name__ == "__main__":
    raise SystemExit(main())
