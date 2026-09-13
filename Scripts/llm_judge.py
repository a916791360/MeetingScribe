#!/usr/bin/env python3
"""LLM 裁判：把「人工抽检一遍纪要」变成一条命令。

方案《转写与速览纪要质量提升方案》§5.2 要求用**不同厂商**的模型当裁判 ——
同一个模型既写又评会系统性偏袒自己的措辞。默认裁判是 Agnes 的 `agnes-3.0-flash`，
而被评的产出由 DeepSeek 生成；两者不同厂商。同厂模型必须显式加 `--allow-same-vendor`
才能跑，免得某天顺手把裁判换成同一个模型、以为还在做独立评审。

四个维度（各自一次独立调用，不合并 —— 合并会让模型在「举证据」和「打分」之间互相迁就）：

  忠实度  这条陈述在逐字稿里找不到依据？分「内在幻觉（写歪）」与「外在幻觉（编出来）」两类
  覆盖度  先自己列出逐字稿里的关键决定，再看纪要抓住了几个
  信息密度  有多少句是「谁跟谁聊了某话题」式的废话
  可执行性  只看纪要，没参会的人明天知道该做什么吗

打分统一 1~4（4 最好），因为「达标」线要能写成一句话：任意维度 < 3 就算没过。

用法：
  python3 Scripts/llm_judge.py                        # 真实语料，全部 case
  python3 Scripts/llm_judge.py --cases slice1-0-15min  # 只跑一个，省钱
  python3 Scripts/llm_judge.py --dry-run              # 只打印提示词，不调模型
  python3 Scripts/llm_judge.py --check                # 任一维度低于阈值就非零退出

Key 的取法（按顺序，找到就用）：
  1. 环境变量 MS_JUDGE_KEY / MS_JUDGE_BASE_URL / MS_JUDGE_MODEL
  2. ~/.workbuddy/models.json 里 id 与裁判模型同名的条目（本机已有 agnes-3.0-flash）
  3. 钥匙串 service=MeetingScribe.judge-model account=custom

产物（全部 gitignore，因为里面含真实逐字稿片段）：
  <corpus>/judge/<caseId>.json    每场四维打分
  <corpus>/judge/raw/*.json       原始响应，便于回查「模型到底说了什么」
  <corpus>/judge/report.md        汇总表
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_CORPUS = REPO / "docs/verification/quality"

# 默认裁判：与产出模型**不同厂商**。改了它就得想清楚「独立性还在不在」。
DEFAULT_JUDGE_MODEL = "agnes-3.0-flash"
DEFAULT_JUDGE_BASE_URL = "https://apihub.agnes-ai.com/v1"

# 裁判的 max_tokens。⚠️ 这个值是「思考链 + 正文」的总预算：
# agnes-3.0-flash 带推理，预算给少了会出现 `finish_reason=length` 且正文为空 ——
# 正是 App 那侧 P0-3 修过的病根。宁可给大，反正裁判的产出很短。
JUDGE_MAX_TOKENS = 6000

DIMENSIONS = {
    "faithfulness": "忠实度",
    "coverage": "覆盖度",
    "density": "信息密度",
    "actionability": "可执行性",
}
# 达标线：任意维度中位数 < 3 就算没过。四维同权，不给「可执行性」加权 ——
# 会被权重掩盖的，恰恰是最容易退化的那一维。
PASS_THRESHOLD = 3

RUBRIC = """你的输出必须是**一个 JSON 对象**，不要有多余文字、不要 markdown 代码围栏。
JSON 里必须有整数字段 "score"（取值 1/2/3/4），以及说明理由的字段。"""


def dimension_prompt(dim: str, transcript: str, product: str) -> str:
    """按 §5.2 的问法构造提示词。问法保持口语化 —— 让裁判「找证据」，别让它「评分」。"""
    head = f"# 逐字稿\n\n{transcript}\n\n# 待评的产出（速览 + 纪要）\n\n{product}\n\n"
    if dim == "faithfulness":
        body = """# 任务：忠实度
逐条检查产出里的每个事实性陈述，指出**在逐字稿里找不到依据**的条目。
- 只报「逐字稿里没有依据」的；措辞不同、详略不同、把口语润成书面语**不算**问题。
- 「内在幻觉」= 把逐字稿里的信息写歪了（时间、数字、人名、因果）；「外在幻觉」= 补了逐字稿没有的事实。
- **同一个信息点的同一个偏差只算一处**，不要为写法变体重复计数。
  例：产出把「赵某某」写成「赵某梅」，这是**一处**内在幻觉，不要再把正确的那个名字也列一遍。
- 拿不准的，kind 写「存疑」，不要硬判 —— 宁可少报，不要误报：
  一份充满误报的清单会让人去修没坏的东西。
输出 JSON：{"score": 1-4, "unsupported": [{"claim": "产出里的原话", "kind": "内部|外部|存疑"}], "note": "..."}
score 含义：4 = 没有无依据陈述；3 = 仅 1 处轻微；2 = 多处，或 1 处实质性的；1 = 大量，或关键结论失真。"""
    elif dim == "coverage":
        body = """# 任务：覆盖度
先**自己**从逐字稿里列出关键决定（含明确结论、明确排期、明确取舍的事项；只作为讨论过程出现、没有结论的不算），
再检查产出的速览与纪要覆盖了其中几个。
输出 JSON：{"score": 1-4, "keyDecisions": ["..."], "covered": ["..."], "missed": ["..."], "note": "..."}
score 含义：4 = 覆盖 ≥90%；3 = ≥70%；2 = ≥40%；1 = <40%。"""
    elif dim == "density":
        body = """# 任务：信息密度
找出产出里属于「谁跟谁聊了某个话题」式的**废话句**：不含结论、不含数据、不含待办、不含分歧、不含风险的句子。
注意：「本次会议围绕X展开」「会上介绍了…」这类起兴句也算废话。
输出 JSON：{"score": 1-4, "fluff": ["..."], "note": "..."}
score 含义：4 = 0 句；3 = 1 句；2 = 2~3 句；1 = ≥4 句。"""
    elif dim == "actionability":
        body = """# 任务：可执行性
只看这份产出，一个**没参会的人**明天能知道该做什么吗？逐条看待办：有没有明确动作、对象、时间。
输出 JSON：{"score": 1-4, "missing": ["..."], "note": "..."}
score 含义：4 = 每条待办都有动作+对象+时间；3 = 多数有；2 = 只有笼统方向；1 = 看不出要做什么。"""
    else:
        raise ValueError(dim)
    return head + body + "\n\n" + RUBRIC


# ---------------------------------------------------------------- 配置


def keychain_lookup(service: str) -> str | None:
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", service, "-a", "custom", "-w"],
            capture_output=True, text=True, timeout=10,
        )
        if out.returncode == 0:
            return out.stdout.strip() or None
    except Exception:
        pass
    return None


def workbuddy_models() -> list[dict]:
    """读 WorkBuddy 的模型表，里面有 url + apiKey。本机零配置就能跑裁判的靠山。"""
    p = pathlib.Path.home() / ".workbuddy/models.json"
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return []


def resolve_judge(args) -> tuple[str, str, str, str]:
    """返回 (base_url, model, key, 来源说明)。"""
    import os
    model = args.model or os.environ.get("MS_JUDGE_MODEL") or DEFAULT_JUDGE_MODEL
    base = args.base_url or os.environ.get("MS_JUDGE_BASE_URL")
    key = os.environ.get("MS_JUDGE_KEY")
    origin = []
    if base:
        origin.append("环境变量 MS_JUDGE_BASE_URL")
    if key:
        origin.append("环境变量 MS_JUDGE_KEY")
    if not (base and key):
        for entry in workbuddy_models():
            if entry.get("id") == model:
                base = base or entry.get("url")
                key = key or entry.get("apiKey")
                origin.append("~/.workbuddy/models.json")
                break
    if not (base and key):
        k = keychain_lookup("MeetingScribe.judge-model")
        if k:
            key = k
            origin.append("钥匙串 MeetingScribe.judge-model")
    if not base:
        base = DEFAULT_JUDGE_BASE_URL
        origin.append("内置默认地址")
    return base, model, key or "", "、".join(origin) or "无（缺 Key）"


def vendor_of(model_id: str) -> str:
    """取厂商标识：`deepseek-v4.1-flash` → `deepseek`，`agnes-3.0-flash` → `agnes`。"""
    m = re.match(r"[A-Za-z]+", (model_id or "").strip())
    return (m.group(0) if m else (model_id or "").strip()).lower()


def summarizer_vendor_of(run: dict) -> str:
    """从 run 里的 `summaryModel`（形如「自定义兼容接口 · deepseek-v4.1-flash」）取厂商。"""
    raw = ((run.get("analysis") or {}).get("summaryModel") or "")
    tail = raw.split("·")[-1].strip()
    return vendor_of(tail)


# ---------------------------------------------------------------- 调用


def compose_product(run: dict, limit: int = 12000) -> str:
    """把速览与纪要拼成裁判要看的「产出」。"""
    a = run.get("analysis") or {}
    parts = []
    if a.get("headline"):
        parts.append("## 一句话结论\n" + a["headline"])
    if a.get("overviewText"):
        parts.append("## 速览\n" + a["overviewText"])
    for b in a.get("overviewBullets") or []:
        parts.append("- " + b)
    if a.get("minutesText"):
        parts.append("## 纪要\n" + a["minutesText"])
    if a.get("decisions"):
        parts.append("## 决策\n" + "\n".join(
            f"- {d.get('label', '')}" for d in a["decisions"]))
    if a.get("actions"):
        parts.append("## 待办\n" + "\n".join(
            f"- {x.get('label', '')}（{x.get('owner') or '未指定'}）" for x in a["actions"]))
    text = "\n\n".join(parts)
    if len(text) > limit:
        text = text[:limit] + "\n\n（产出过长，已截断）"
    return text


def compose_transcript(case: dict, limit: int = 60000) -> str:
    segs = case.get("segments") or []
    text = "\n".join(f"[{int(s.get('start', 0))}s] {s.get('text', '')}" for s in segs)
    if len(text) > limit:
        text = text[:limit] + "\n\n（逐字稿过长，已截断）"
    return text


def extract_json(text: str) -> dict:
    """宽容解析：模型经常裹一层代码围栏或前后加一句客套话。"""
    if not text:
        raise ValueError("响应正文为空")
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if fence:
        text = fence.group(1)
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError(f"响应里找不到 JSON 对象：{text[:200]}")
    return json.loads(text[start:end + 1])


def call_judge(base_url: str, model: str, key: str, prompt: str,
               retries: int = 2, verbose: bool = False) -> tuple[str, dict]:
    url = base_url.rstrip("/")
    if not url.endswith("/chat/completions"):
        url += "/chat/completions"
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.1,
        "max_tokens": JUDGE_MAX_TOKENS,
        "stream": False,
    }
    last_err: Exception | None = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(
            url, data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                body = json.loads(resp.read().decode("utf-8"))
            choice = (body.get("choices") or [{}])[0]
            content = ((choice.get("message") or {}).get("content") or "").strip()
            finish = choice.get("finish_reason")
            # ⚠️ 与 App 同一条铁律：`length` 就是截断，正文非空也算。
            # 裁判产出很短，所以这里直接当硬错误报出来，不许静默按空处理。
            if finish == "length":
                raise RuntimeError(
                    f"裁判被截断（finish_reason=length）。正文 {len(content)} 字。"
                    f"把 JUDGE_MAX_TOKENS 调大再跑。")
            if not content:
                raise RuntimeError(
                    f"裁判正文为空（finish_reason={finish}）。"
                    f"推理模型可能把预算花在思考上了，把 JUDGE_MAX_TOKENS 调大。")
            return content, body
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:300]
            last_err = RuntimeError(f"HTTP {e.code}：{detail}")
        except Exception as e:  # 网络抖动、超时、解析失败
            last_err = e
        if attempt < retries:
            wait = 2 ** attempt
            print(f"    第 {attempt + 1} 次失败（{last_err}），{wait}s 后重试…", file=sys.stderr)
            time.sleep(wait)
    raise RuntimeError(f"裁判调用失败：{last_err}")


# ---------------------------------------------------------------- 主流程


def load_rows(corpus: pathlib.Path) -> list[tuple[str, dict, dict]]:
    out = []
    for case_path in sorted((corpus / "cases").glob("*.json")):
        run_path = corpus / "runs" / case_path.name
        if not run_path.exists():
            continue
        case = json.loads(case_path.read_text(encoding="utf-8"))
        run = json.loads(run_path.read_text(encoding="utf-8"))
        if not run.get("ok"):
            print(f"跳过 {case['caseId']}：这一场管线失败/降级，没有产出可评", file=sys.stderr)
            continue
        out.append((case["caseId"], case, run))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=None)
    ap.add_argument("--cases", default="", help="逗号分隔的 caseId，只跑这几个")
    ap.add_argument("--model", default=None)
    ap.add_argument("--base-url", default=None)
    ap.add_argument("--dry-run", action="store_true", help="只打印提示词，不调模型")
    ap.add_argument("--check", action="store_true", help="任一维度低于阈值就非零退出")
    ap.add_argument("--repeat", type=int, default=1,
                    help="每个维度调用几次取中位（单次 LLM 打分有 ±1 抖动，想稳就设 3）")
    ap.add_argument("--allow-same-vendor", action="store_true",
                    help="允许裁判与被评产出同厂（**不建议**：会系统性偏袒自己的措辞）")
    args = ap.parse_args()

    corpus = pathlib.Path(args.corpus) if args.corpus else DEFAULT_CORPUS
    rows = load_rows(corpus)
    if args.cases:
        want = {c.strip() for c in args.cases.split(",") if c.strip()}
        rows = [r for r in rows if r[0] in want]
    if not rows:
        print(f"没有可评的 case（语料：{corpus}）。先跑 --run 产出 runs/。", file=sys.stderr)
        return 1

    base, model, key, origin = resolve_judge(args)
    print(f"# LLM 裁判\n")
    print(f"- 裁判模型：`{model}`（来源：{origin}）")
    print(f"- 待评产出模型：{summarizer_vendor_of(rows[0][2]) or '未知'}"
          f"（来自 run 里的 summaryModel）")

    same_vendor = []
    for cid, _case, run in rows:
        sv = summarizer_vendor_of(run)
        if sv and sv == vendor_of(model):
            same_vendor.append((cid, sv))
    if same_vendor:
        msg = ("裁判与被评产出**同厂**：" +
               "、".join(f"{c}({v})" for c, v in same_vendor))
        if not args.allow_same_vendor:
            print(f"\n✗ {msg}\n  同厂裁判会系统性偏袒自己那一族的措辞，"
                  f"四维分数不再是独立证据。确要这么跑就加 --allow-same-vendor。", file=sys.stderr)
            return 2
        print(f"\n⚠️ {msg}（已按 --allow-same-vendor 继续）")

    if not key and not args.dry_run:
        print("\n✗ 没有拿到裁判的 Key。设 MS_JUDGE_KEY，"
              "或把该模型写进 ~/.workbuddy/models.json，或存进钥匙串 "
              "MeetingScribe.judge-model（account=custom）。", file=sys.stderr)
        return 2

    out_dir = corpus / "judge"
    raw_dir = out_dir / "raw"
    out_dir.mkdir(parents=True, exist_ok=True)
    raw_dir.mkdir(parents=True, exist_ok=True)

    results: dict[str, dict] = {}
    for cid, case, run in rows:
        transcript = compose_transcript(case)
        product = compose_product(run)
        print(f"\n## {cid}（{case.get('label', '')}）"
              f"　逐字稿 {len(transcript)} 字 / 产出 {len(product)} 字")
        entry = {"caseId": cid, "judgeModel": model,
                 "judgeBaseUrl": base,
                 "productModel": summarizer_vendor_of(run),
                 "dimensions": {}}
        for dim, zh in DIMENSIONS.items():
            prompt = dimension_prompt(dim, transcript, product)
            if args.dry_run:
                print(f"  - {zh}：提示词 {len(prompt)} 字（--dry-run，未调用）")
                continue
            print(f"  - {zh}：调用中…", end="", flush=True)
            t0 = time.time()
            scores: list[int] = []
            parsed_runs: list[dict] = []
            last_error: str | None = None
            for i in range(max(1, args.repeat)):
                try:
                    content, body = call_judge(base, model, key, prompt)
                    (raw_dir / f"{cid}-{dim}"
                     f"{'' if args.repeat == 1 else f'-{i + 1}'}.json").write_text(
                        json.dumps({"prompt": prompt, "response": body},
                                   ensure_ascii=False, indent=1), encoding="utf-8")
                    parsed = extract_json(content)
                except Exception as e:
                    last_error = str(e)
                    continue
                score = parsed.get("score")
                if not isinstance(score, int) or not 1 <= score <= 4:
                    last_error = f"score 不是 1~4 的整数：{score!r}"
                    continue
                scores.append(score)
                parsed_runs.append(parsed)
            if not scores:
                entry["dimensions"][dim] = {"score": None, "error": last_error}
                print(f" 失败：{last_error}")
                continue
            # 多次跑取中位：单次 LLM 打分有 ±1 的抖动，用一次的数当门槛太脆。
            # 抖动本身如实留在 runs 里，便于回看「这个分数稳不稳」。
            merged = dict(parsed_runs[len(parsed_runs) // 2])
            merged["score"] = int(statistics.median(scores))
            merged["runs"] = scores
            merged["elapsedSeconds"] = round(time.time() - t0, 1)
            entry["dimensions"][dim] = merged
            extra = (merged.get("fluff") or merged.get("missed")
                     or merged.get("unsupported") or [])
            spread = f"，各次 {scores}" if len(set(scores)) > 1 else ""
            print(f" {merged['score']}/4"
                  + (f"，举出 {len(extra)} 处" if isinstance(extra, list) and extra else "")
                  + spread)
        results[cid] = entry
        (out_dir / f"{cid}.json").write_text(
            json.dumps(entry, ensure_ascii=False, indent=1), encoding="utf-8")

    if args.dry_run:
        print("\n（--dry-run 结束，未调用模型、未写产物）")
        return 0

    # ---------------- 汇总
    dims = list(DIMENSIONS)
    lines = ["# LLM 裁判报告", "",
             f"- 裁判模型：`{model}`（来源：{origin}）",
             f"- 待评 case：{len(results)}",
             f"- 打分口径：1~4，4 最好；**任一维度中位数 < {PASS_THRESHOLD} 即未过**", "",
             "| case | " + " | ".join(DIMENSIONS[d] for d in dims) + " | 均值 |",
             "|---" * (len(dims) + 2) + "|"]
    per_dim: dict[str, list[int]] = {d: [] for d in dims}
    for cid, entry in results.items():
        cells, vals = [], []
        for d in dims:
            s = (entry["dimensions"].get(d) or {}).get("score")
            cells.append("—" if s is None else str(s))
            if isinstance(s, int):
                vals.append(s)
                per_dim[d].append(s)
        mean_cell = f"{statistics.mean(vals):.2f}" if vals else "—"
        lines.append(f"| {cid} | " + " | ".join(cells) + f" | {mean_cell} |")
    lines += ["", "## 维度判定", "", "| 维度 | 中位数 | 判定 |", "|---|---|---|"]
    failures = []
    for d in dims:
        vals = per_dim[d]
        if not vals:
            lines.append(f"| {DIMENSIONS[d]} | — | 不可算 |")
            continue
        med = statistics.median(vals)
        ok = med >= PASS_THRESHOLD
        lines.append(f"| {DIMENSIONS[d]} | {med:g} | {'达标' if ok else '未达'} |")
        if not ok:
            failures.append(f"{DIMENSIONS[d]} 中位数 {med:g} < {PASS_THRESHOLD}")
    lines += ["", "## 逐条细节", ""]
    for cid, entry in results.items():
        lines.append(f"### {cid}")
        for d in dims:
            got = entry["dimensions"].get(d) or {}
            if got.get("error"):
                lines.append(f"- **{DIMENSIONS[d]}**：跑失败（{got['error']}）")
                continue
            if got.get("score") is None:
                lines.append(f"- **{DIMENSIONS[d]}**：未跑")
                continue
            lines.append(f"- **{DIMENSIONS[d]}** {got['score']}/4：{got.get('note', '')}")
            for key_name, label in (("unsupported", "无依据"), ("missed", "漏掉"),
                                    ("fluff", "废话"), ("missing", "缺要素")):
                items = got.get(key_name)
                if isinstance(items, list) and items:
                    for it in items[:6]:
                        if isinstance(it, dict):
                            it = f"{it.get('claim', '')}（{it.get('kind', '')}）"
                        lines.append(f"    - {label}：{it}")
        lines.append("")
    report = "\n".join(lines)
    (out_dir / "report.md").write_text(report, encoding="utf-8")
    print("\n" + report)
    print(f"\n产物：{out_dir.relative_to(REPO) if out_dir.is_relative_to(REPO) else out_dir}"
          f"（已 gitignore，含真实逐字稿片段）")

    if args.check:
        if failures:
            print("\n✗ 未过：" + "；".join(failures), file=sys.stderr)
            return 1
        if args.repeat == 1:
            # 实测记录（2026-09-14，slice1-0-15min）：忠实度三次跑出 [2, 4, 4]。
            # 也就是说 --repeat 1 时「达标/未达」的结论本身可能是掷硬币的结果。
            print("\n⚠️ 这是单次跑（--repeat 1）。本机实测同一份产出的同一维度出现过 "
                  "[2, 4, 4] 的抖动 —— 拿单次分数当结论前，先跑 --repeat 3 看中位。")
        print(f"\n✓ 四个维度都 ≥ {PASS_THRESHOLD}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
