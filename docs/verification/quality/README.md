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

副作用要认清：CI 跑不了这套指标——它依赖本机素材。
阶段 3 若要进 CI，需要另外造一份**合成语料**（编造的会议逐字稿）作为免密夹具，
那是另一件事，别把真实数据当成 CI 夹具。

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
```

`--run` 走的是 `Tests/MeetingScribeTests/QualityEvalTests.swift`，它**直接调
`MeetingSummaryEngine().analyze(...)`**，不是另写一套 HTTP 请求。测的必须是 App 真实走的路径，
否则「接口通」会被误读成「功能对」。

不设 `MS_E2E_KEY` 时那支测试自动 `XCTSkip`，不会让常规 `swift test` 变红。

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
- LLM 裁判四维（忠实度/覆盖度/信息密度/可执行性）是阶段 3-3 的脚本，尚未建。

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
| `finishReason` | 目前为 `null`；P0-3 起由引擎回传（截断判定要用它） |
| `localFallback` | 降级时用户实际看到的本地规则产物规模 |
| `analysis` | 成功时的完整 `MeetingAnalysis` |
