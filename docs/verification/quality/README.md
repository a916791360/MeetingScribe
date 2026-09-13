# 质量评测集与指标

回答一个问题：**「速览/纪要变好了」是不是真的？**

在它之前，这个问题只能靠印象回答；而印象恰好是「整场静默降级」这类缺陷最擅长骗过的东西——
它不报错、不告警，返回一份看起来正常但很差的本地规则输出。

数字口径见《[转写与速览纪要质量提升方案](../../转写与速览纪要质量提升方案.md)》§5.1，
执行顺序见《[质量提升执行计划](../../质量提升执行计划.md)》阶段 0。

---

## ⚠️ 这个目录里的数据不进仓库

`cases/`、`runs/`、`baseline.json`、`manifest.json`、`report.*` 全部在 `.gitignore` 里。

原因：评测集是从**你的真实会议录音**导出的逐字稿，含客户名、公司名、内部规划。
本项目定位是「本地优先、隐私不出机」，夹具就不该往 git 历史里塞
（即使仓库是私有的，历史也很难真正清除）。

仓库里只提交：**脚本**（`Scripts/`）和**这份说明**。换台机器照着重建即可。

副作用要认清：**CI 跑不了这份真实语料**——它依赖本机素材，而 CI 上没有你的会议录音。

阶段 3 已经把这件事办了：另造了一份**合成语料**放在同级的 [../synthetic/](../synthetic/)（编造的会议，
可以提交），CI 用它跑**能离线判定的那部分指标**（段数 / 字数 / 小标题数 / 空话动词）。
两套语料共用 `Scripts/quality_report.py` 的同一份口径，不会各算各的 —— 抄第二份指标代码
就是两边口径漂移的开始。

**分工要记牢：CI 绿 ≠ 内容好。** CI 只保证「度量没失真」；模型写得好不好，
只能在这台机器上用真实语料跑（`--run`）和用裁判打分（`--judge`）。

---

## 怎么用

```bash
# 1. 构建评测集（只读数据根，输出到 cases/）
python3 Scripts/build_eval_set.py
python3 Scripts/build_eval_set.py --list   # 先看有哪些会话、怎么切片

# 2. 跑真实管线 + 出指标（需要总结模型的 Key）
MS_E2E_KEY="$(security find-generic-password -s MeetingScribe.summary-model -a custom -w)" \
  Scripts/quality_report.sh --run --baseline

# 3. 改完代码后再跑，与基线对比
MS_E2E_KEY="…" Scripts/quality_report.sh --run --diff

# 4. 免密的那条路（CI 同款）：合成语料自测，判定与期望不一致就非零退出
Scripts/quality_report.sh --check

# 5. 让异厂模型当裁判，四维打分（忠实度/覆盖度/信息密度/可执行性）
Scripts/quality_report.sh --judge --repeat 3
```

`--run` 走的是 `Tests/MeetingScribeTests/QualityEvalTests.swift`，它**直接调
`MeetingSummaryEngine().analyze(...)`**，不是另写一套 HTTP 请求。测的必须是 App 真实走的路径，
否则「接口通」会被误读成「功能对」。

不设 `MS_E2E_KEY` 时那支测试自动 `XCTSkip`，不会让常规 `swift test` 变红。

### 裁判为什么要 `--repeat`

单次 LLM 打分的抖动不小。本机实测（2026-09-14，同一个 case 的同一维度，「忠实度」）
三次跑出 **`[2, 4, 4]`** —— `--repeat 1` 时「达标 / 未达」的结论本身可能是掷硬币的结果。
所以脚本默认支持 `--repeat N` 取中位，抖动也如实记进 `judge/<caseId>.json` 的 `runs` 字段里。
`--check` 在 `--repeat 1` 时会主动提示这一点。

裁判默认用 **Agnes 的 `agnes-3.0-flash`**（与被评产出的 DeepSeek 不同厂商）。
同厂模型必须显式加 `--allow-same-vendor` 才能跑：同一个模型既写又评会系统性偏袒自己的措辞。

### CI 在跑什么

`.github/workflows/quality.yml` 两个任务：

| 任务 | 跑什么 | 需要密钥 |
|---|---|---|
| `metrics` | `Scripts/tests/test_quality_report.py` + 合成语料 `--check` | 不需要 |
| `swift` | `swift build` / `swift test`（真实管线那支自动跳过） | 不需要 |

macOS runner 按 10 倍计入用量，所以只在 `main` 与 PR 上跑，并取消被后推提交取代的运行。

---

## 评测集现状（本机构建结果）

素材受限：数据根在一次事故后重建，现存只有 2 场会话。按计划允许的「长会切片」做法凑出 5 例：

| case | 时长 | 来源 | 期望 |
|---|---|---|---|
| `slice1-0-15min` | 15 min | 长会切片 | 有内容 |
| `slice2-15-30min` | 15 min | 长会切片 | 有内容 |
| `slice3-30-45min` | ~14.7 min | 长会切片 | 有内容 |
| `long-full` | 44.7 min | 完整长会 | 有内容 |
| `too-short` | 26 s | 误录到在线视频的推广语 | **走空态** |

**已知缺口**（脚本会打印，不掩盖）：

- 最长逐字稿 13037 字符 < 分章阈值 24000 → **分章路径没有任何 case 覆盖**，
  P2-4（分章模板噪声）做完也无法验证。需要一场 >60 分钟、逐字稿 >2.4 万字的会。
- 领域专名命中率需要人工标注「本场正确专名表」——属于人工金标准工作，尚未做。
- 真实语料只有 5 例，单 case 的分数波动会直接影响判定；阶段性结论要看多轮中位。

## LLM 裁判的四维（决定「人工抽检」可以省到什么程度）

`--judge` 会为每个 case 调四次裁判（每维一次，不合并 —— 合并会让模型在「举证据」与
「打分」之间互相迁就）。打分 1~4，**任一维度中位数 < 3 即未过**：

| 维度 | 问法 | 判它有没有效的办法 |
|---|---|---|
| 忠实度 | 「哪条陈述在逐字稿里找不到依据？」分内在/外在幻觉 | 拿已知被改坏的产出去试，看它抓不抓得到 |
| 覆盖度 | 「先自己列出关键决定，再看纪要覆盖几个」 | 与人工金标准对一遍 |
| 信息密度 | 「有多少句是『谁跟谁聊了某话题』式的废话？」 | 与空话检测的客观计数对一遍 |
| 可执行性 | 「只看纪要，没参会的人明天知道做什么吗？」 | **与 `actionsWithOwnerRatio` 对不对得上** |

最后一行是最值钱的一条校验：2026-09-14 首次实跑，裁判给 `slice1-0-15min` 的可执行性
**2/4**，理由写的是「除 AI 方案外其余待办既无责任人也无时间节点」——而同一场的客观指标
`actionsWithOwnerRatio` = 0.125（远低于 30% 的线）。**一个只会读文本的裁判，独立地
复现了客观指标算出来的同一个结论**。这种「两条独立路径指向同一结论」才算证据；
一条路径自己说自己是好是坏，不算。

**期望空态的 case 只评忠实度**，其余三维记 `n/a` 且不计入统计。
`too-short` 那场本来就不该有内容，去量它「有多少废话」「明天该做什么」必然得低分，
而这个低分会被误读成质量差 —— 这是本项目第 7 次同型口径错
（详见技能 `llm-content-quality-eval` 的 `references/metric-pitfalls.md` 事故 7）。
报告里三种状态是分开的：**分数 / `n/a` 不适用 / 跑失败**。

---

## 人工金标准（可选，但最值钱）

上面都是**客观指标**，不需要金标准就能算。金标准解锁的是「覆盖度」：
逐字稿里的 5 个关键决定，纪要抓住了几个。

做法：在 `cases/<caseId>.golden.md` 里手写一份理想纪要（每场约 30 分钟）。脚本会认这个文件名，
存在时在报告里多出一块「覆盖度」对照。没有就跳过，不影响其余指标。

---

## 字段说明

`cases/<caseId>.json` 是输入：

| 字段 | 含义 |
|---|---|
| `caseId` / `label` | 标识与可读名（报告里只用这两个，不含会议标题） |
| `sliceStart` / `sliceEnd` | 该 case 在原会中的时间窗口（秒） |
| `expect` | `content` = 期望有内容；`emptyState` = 期望走空态 |
| `segments[]` | `{start, end, text, confidence}`，与 `session.json` 的 `transcriptSegments` 同构 |

`runs/<caseId>.json` 是输出（由 Swift 测试写）：

| 字段 | 含义 |
|---|---|
| `ok` / `errorType` / `errorMessage` | 真实管线是否抛错、抛的哪种错 |
| `elapsedSeconds` | 端到端耗时（P0-4 改成两段式后要看它有没有翻倍） |
| `inputSegmentCount` / `inputCharCount` | 原始逐字稿规模 |
| `preparedSegmentCount` / `preparedCharCount` | 引擎**实际吃到**的规模（P0-1 后有区别） |
| `transcriptCharsSentToModel` | 拼成 `[秒] 文本` 后真正发出去的字符数 |
| `finishReason` | 引擎回传的截断判定依据（P0-3 起）。健康值 `stop`；出现 `length` 就是被截断了 |
| `localFallback` | 降级时用户实际看到的本地规则产物规模 |
| `analysis` | 成功时的完整 `MeetingAnalysis` |
