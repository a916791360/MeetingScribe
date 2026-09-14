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
JUDGE_MAX_TOKENS = 12000

DIMENSIONS = {
    "faithfulness": "忠实度",
    "coverage": "覆盖度",
    "density": "信息密度",
    "actionability": "可执行性",
}
# 哪些维度对「期望空态」的 case 适用。
#
# ⚠️ 首版全量实跑当场暴露了这个口径错：`too-short`（误录到在线视频的推广语，
# 期望就是**什么都不产出**）被按四维打分，可执行性拿 1/4 —— 理由是"没有待办、没有责任人"。
# 可它**本来就不该有待办**。把不适用的指标拿来判，必然得低分，
# 而这个低分会被读成"这一场质量差"。同型事故在本项目已经第 7 次（见
# docs/转写与速览纪要质量提升方案.md 与 .learnings）。
#
# 空态场唯一有意义的问法是：**它有没有编造出不存在的会议内容**。
EMPTY_STATE_DIMENSIONS = ("faithfulness",)
NOT_APPLICABLE = "该场期望空态（本来就不该有内容），这一维不适用 —— 不是 0 分"
# 达标线：任意维度中位数 < 3 就算没过。四维同权，不给「可执行性」加权 ——
# 会被权重掩盖的，恰恰是最容易退化的那一维。
PASS_THRESHOLD = 3

RUBRIC = """你的输出必须是**一个 JSON 对象**，不要有多余文字、不要 markdown 代码围栏。
JSON 里必须有整数字段 "score"（取值 1/2/3/4），以及说明理由的字段。
**列举类字段最多 8 条、每条不超过 30 字**，只给最能说明问题的例子 ——
穷举会让回复被截断，反而什么也拿不到。"""


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


# ---------------------------------------------------------------- 报告渲染
#
# 渲染与「跑」分开：报告是**能从产物重建**的东西。
# 为什么必须分开：报告格式总会改（加一列、改判定口径），而**分数是花真钱跑出来的**。
# 不分开的话，每次改格式都得重调一遍模型 —— 而重跑会得到**不同的分数**（抖动），
# 于是「只改了个排版」会顺手把上周的结论也改掉。`--report-only` 就是为这件事存在的。


def render_report(results: dict, model: str, origin: str, repeat: int,
                  product_vendor: str) -> tuple[str, list[str], list[str]]:
    """把 results 渲染成报告。返回 (报告正文, 未达标清单, 不稳定清单)。

    纯函数：不调模型、不写文件 —— 所以「跑完直接渲染」与「--report-only 重渲染」
    拿到的一定是同一份结果。
    """
    dims = list(DIMENSIONS)
    empty_cases = [cid for cid, e in results.items() if e.get("expect") == "emptyState"]
    content_cases = [cid for cid, e in results.items() if e.get("expect") != "emptyState"]
    lines = ["# LLM 裁判报告", "",
             f"- 裁判模型：`{model}`（来源：{origin}）",
             f"- 待评产出模型：`{product_vendor or '未知'}`",
             f"- 待评 case：{len(results)}"
             f"（有内容 {len(content_cases)}　期望空态 {len(empty_cases)}）",
             # 产物必须自带"怎么跑出来的"：同一份产出的分数会随 repeat 变，
             # 不写下来，过两周看这张表就分不清是稳的还是掷硬币掷出来的。
             f"- 每维重复次数：{repeat}"
             + ("　⚠️ **单次跑，仅供参考**（实测同维度出现过 [2,4,4] 的抖动）"
                if repeat == 1 else ""),
             f"- 打分口径：1~4，4 最好；**任一维度中位数 < {PASS_THRESHOLD} 即未过**",
             ]
    if empty_cases:
        lines.append(
            f"- **`n/a` = 不适用**：{'、'.join(f'`{c}`' for c in empty_cases)} "
            f"期望走空态（本来就不该有内容），只评{'、'.join(DIMENSIONS[d] for d in EMPTY_STATE_DIMENSIONS)}，"
            f"其余维度不计入统计 —— 对一场本该没内容的会去量「有多少废话」「明天该做什么」，"
            f"必然得低分，而这个低分会被误读成质量差")
    lines += ["",
              "| case | " + " | ".join(DIMENSIONS[d] for d in dims) + " | 均值 |",
              "|---" * (len(dims) + 2) + "|"]
    per_dim: dict[str, list[int]] = {d: [] for d in dims}
    for cid, entry in results.items():
        cells, vals = [], []
        for d in dims:
            got = entry["dimensions"].get(d) or {}
            s = got.get("score")
            if s is None:
                cells.append("n/a" if got.get("notApplicable") else "—")
            else:
                cells.append(str(s))
            if isinstance(s, int):
                vals.append(s)
                # ⚠️ 聚合**只收有内容的场**。
                # 空态场也有一维忠实度（"有没有编造出不存在的会议内容"），但它和有内容场
                # 问的**不是同一个问题**，而且"空场不乱编"太容易拿到 4 分 —— 混进来等于
                # 白送一个高分，把真实缺陷的中位抬上去。实测（2026-09-14）就踩了这个：
                # 忠实度聚合一度显示「4 场未达 / 1 场达标」，那个"1 场达标"就是空态场。
                if cid in content_cases:
                    per_dim[d].append(s)
        mean_cell = f"{statistics.mean(vals):.2f}" if vals else "—"
        if len(vals) < len(dims):
            # 均值只按适用的维度算 —— 不写清楚，空态场的 4.00 会被拿去和四维均值比。
            mean_cell += f"（{len(vals)} 维）"
        lines.append(f"| {cid} | " + " | ".join(cells) + f" | {mean_cell} |")

    lines += ["", "## 维度判定", "",
              "| 维度 | 中位数 | 各场中位 | 稳定性 | 判定 |",
              "|---|---|---|---|---|"]
    failures, unstable = [], []
    for d in dims:
        vals = per_dim[d]
        if not vals:
            reason = ("本语料没有适用这一维的**有内容** case" if any(
                (e["dimensions"].get(d) or {}).get("notApplicable") for e in results.values())
                else "本轮没有拿到分数")
            lines.append(f"| {DIMENSIONS[d]} | — | — | — | 不可算（{reason}） |")
            continue
        med = statistics.median(vals)
        # 稳定性判据：**看每一场的中位落在线的哪一侧**，而不是算方差。
        #   - 每场都 < 线  → 「未达」是稳的（换一场也还是未达），可以当依据；
        #   - 每场都 ≥ 线  → 「达标」是稳的；
        #   - 有的达标有的未达 → 这个中位数**随语料构成变化**，谁拿它下结论谁倒霉。
        # 实测（2026-09-14，repeat=3）：忠实度 2/2/2/2、覆盖度 4/4/4/4、可执行性 1/2/2/2
        # 都是一致的；而信息密度 3/4/2/1 —— 它的中位 2.5 就是撞线的产物。
        lows = [v for v in vals if v < PASS_THRESHOLD]
        if not lows:
            judge, stable = "达标", "一致（每场都达标）"
        elif len(lows) == len(vals):
            judge, stable = "未达", "一致（每场都未达）"
        else:
            judge = "达标" if med >= PASS_THRESHOLD else "未达"
            stable = (f"⚠️ **不一致（{len(lows)} 场未达 / {len(vals) - len(lows)} 场达标）"
                      f"→ 随语料构成变化，不能当依据**")
            unstable.append(f"{DIMENSIONS[d]}（各场中位 {'/'.join(str(int(v)) for v in vals)}）")
        lines.append(f"| {DIMENSIONS[d]} | {med:g} | "
                     f"{'/'.join(str(int(v)) for v in vals)} | {stable} | {judge} |")
        if judge == "未达":
            failures.append(f"{DIMENSIONS[d]} 中位数 {med:g} < {PASS_THRESHOLD}")

    if failures:
        # ⚠️ 这条不是客套话，是实测教训（2026-09-14，long-full 忠实度）：
        # 同一份产出跑四次得到 [3,1,2,3]，而最低那次的三条指控回到逐字稿一核对 ——
        #   · "12份"被判"无依据"，可逐字稿 [2266s] 明写「那就是12份」→ **误报**；
        #   · "8小时超时"被判"被误记为 80"，可逐字稿里**既没有「8小时」也没有「八小时」**
        #     → 它替原文编了一个它想要的版本，用来证明产出写错了 → **虚构引文**；
        #   · "六亿个同事"确实错（应为"六个"），但那是**转写听错**、产出如实保留 ——
        #     它在判**正确性**，不是**忠实性**。
        # 所以负分只是**线索**，不是结论。抽 1~2 条回原文核对是必经步骤，不是可选项。
        lines += ["", "> ⚠️ **负分先核对，再动手改代码。** 实测（2026-09-14）：裁判的指控里出现过"
                      "**误报**（逐字稿明写的句子被判「无依据」）、**虚构引文**"
                      "（它替原文编了一个版本来证明产出写错）、以及把**转写听错**"
                      "当成**模型幻觉**。它给的是线索，不是判决 —— "
                      "**任何负分在拿去改产品之前，必须抽 1~2 条回到逐字稿核对。**"]

    if empty_cases:
        lines += ["", "## 期望空态的 case（单独判，不混进上面的中位）", "",
                  "`n/a` 的维度本来就不该测（见上）。它的**忠实度**仍然要测 —— 问的是"
                  "「有没有编造出不存在的会议内容」，**判定也单独走**：", "",
                  "| case | 忠实度 | 判定 |", "|---|---|---|"]
        for cid in empty_cases:
            got = results[cid]["dimensions"].get("faithfulness") or {}
            s = got.get("score")
            if got.get("error"):
                lines.append(f"| {cid} | — | 跑失败（{got['error']}） |")
                continue
            if not isinstance(s, int):
                lines.append(f"| {cid} | — | 不可算 |")
                continue
            ok = s >= PASS_THRESHOLD
            lines.append(f"| {cid} | {s} | {'达标' if ok else '未达'} |")
            if not ok:
                # 空态场编造内容 = 无中生有一场会，是最严重的一类问题，必须计入失败。
                failures.append(
                    f"{cid}（期望空态）忠实度 {s} < {PASS_THRESHOLD}：编造了不存在的会议内容")

    lines += ["", "## 逐条细节", ""]
    for cid, entry in results.items():
        lines.append(f"### {cid}")
        for d in dims:
            got = entry["dimensions"].get(d) or {}
            if got.get("notApplicable"):
                lines.append(f"- **{DIMENSIONS[d]}**：n/a（{got['notApplicable']}）")
                continue
            if got.get("error"):
                lines.append(f"- **{DIMENSIONS[d]}**：跑失败（{got['error']}）")
                continue
            if got.get("score") is None:
                lines.append(f"- **{DIMENSIONS[d]}**：未跑")
                continue
            runs = got.get("runs") or []
            # 重复跑之间分数不一致时如实标出来：那是这条维度**信噪比**的直接证据，
            # 也是「这个分该不该被采信」的第一手材料。
            spread_note = f"（各次 {runs}）" if len(set(runs)) > 1 else ""
            lines.append(f"- **{DIMENSIONS[d]}** {got['score']}/4{spread_note}："
                         f"{got.get('note', '')}")
            for key_name, label in (("unsupported", "无依据"), ("missed", "漏掉"),
                                    ("fluff", "废话"), ("missing", "缺要素")):
                items = got.get(key_name)
                if isinstance(items, list) and items:
                    for it in items[:6]:
                        if isinstance(it, dict):
                            it = f"{it.get('claim', '')}（{it.get('kind', '')}）"
                        lines.append(f"    - {label}：{it}")
        lines.append("")

    if unstable:
        lines += ["", "## ⚠️ 不能当依据的维度", "",
                  "下面这些维度**各场中位落在了线的两侧** —— 也就是说「达标还是未达」"
                  "取决于语料里放了哪几场，不取决于产品。**先别用它下结论**："
                  "要么把 `--repeat` 加大到中位稳定，要么承认这条维度在本语料上测不出结论。", ""]
        for u in unstable:
            lines.append(f"- {u}")
    return "\n".join(lines), failures, unstable


def report_only(corpus: pathlib.Path, rows: list[tuple[str, dict, dict]]) -> int:
    """只用已存的 judge/*.json 重渲染报告 —— 不调模型、不花钱。

    用途：报告格式改了要重出，或者想复核两周前那一跑到底写了什么。
    """
    out_dir = corpus / "judge"
    results: dict[str, dict] = {}
    for cid, _case, _run in rows:
        p = out_dir / f"{cid}.json"
        if p.exists():
            results[cid] = json.loads(p.read_text(encoding="utf-8"))
    if not results:
        print(f"{out_dir} 里没有打分结果，先完整跑一次 --judge。", file=sys.stderr)
        return 1
    first = next(iter(results.values()))
    repeat = 1
    for e in results.values():
        for got in (e.get("dimensions") or {}).values():
            repeat = max(repeat, len(got.get("runs") or []))
    report, _failures, unstable = render_report(
        results, first.get("judgeModel", "?"),
        "judge/*.json（本次未调用模型）", repeat, first.get("productModel", ""))
    (out_dir / "report.md").write_text(report, encoding="utf-8")
    print(report)
    print(f"\n产物：{out_dir.relative_to(REPO) if out_dir.is_relative_to(REPO) else out_dir}"
          f"（由已存结果重渲染，未调用模型）")
    if unstable:
        print("\n⚠️ 有维度不能当依据：" + "；".join(unstable), file=sys.stderr)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=None)
    ap.add_argument("--cases", default="", help="逗号分隔的 caseId，只跑这几个")
    ap.add_argument("--model", default=None)
    ap.add_argument("--base-url", default=None)
    ap.add_argument("--dry-run", action="store_true", help="只打印提示词，不调模型")
    ap.add_argument("--check", action="store_true", help="任一维度低于阈值就非零退出")
    ap.add_argument("--report-only", action="store_true",
                    help="不调模型，只用已存的 judge/*.json 重渲染报告"
                         "（改了报告格式后不用再花钱跑一次）")
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

    if args.report_only:
        return report_only(corpus, rows)

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
                 "expect": case.get("expect"),
                 "dimensions": {}}
        # 空态场只跑适用的维度，其余显式标「不适用」——不用 0 也不给低分冒充。
        applicable = (list(DIMENSIONS) if case.get("expect") != "emptyState"
                      else list(EMPTY_STATE_DIMENSIONS))
        for dim in DIMENSIONS:
            if dim not in applicable:
                entry["dimensions"][dim] = {"score": None, "notApplicable": NOT_APPLICABLE}
                print(f"  - {DIMENSIONS[dim]}：n/a（该场期望空态，不适用）")
                continue
            zh = DIMENSIONS[dim]
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
                body = None
                try:
                    content, body = call_judge(base, model, key, prompt)
                    (raw_dir / f"{cid}-{dim}"
                     f"{'' if args.repeat == 1 else f'-{i + 1}'}.json").write_text(
                        json.dumps({"prompt": prompt, "response": body},
                                   ensure_ascii=False, indent=1), encoding="utf-8")
                    parsed = extract_json(content)
                except Exception as e:
                    # 把 finish_reason 一起报出来：解析失败与「被截断」是两种病，
                    # 不写清楚就只能靠猜（首版就吃过这个亏）。
                    finish = None
                    try:
                        finish = ((body or {}).get("choices") or [{}])[0].get("finish_reason")
                    except Exception:
                        pass
                    last_error = str(e) + (f"（finish_reason={finish}）" if finish else "")
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
    report, failures, unstable = render_report(
        results, model, origin, max(1, args.repeat), summarizer_vendor_of(rows[0][2]))
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
        if unstable:
            # 「没未达」不等于「达标是可采信的」：不一致的维度会让 --check 变绿，
            # 而那只是因为碰巧多放了几场达标的。这种绿必须自己说出来。
            print("\n⚠️ 有维度各场中位落在线的两侧，达标与否取决于语料构成："
                  + "；".join(unstable), file=sys.stderr)
        print(f"\n✓ 四个维度都 ≥ {PASS_THRESHOLD}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
