# MeetingScribe 审查报告 · 第 3 批

日期：2026-10-06。GitHub 基线：`bd80e302b88622bb435eb73b47b34b847fb3f86f`，0.11.1 / build 21。本批检查桌面交互、原文编辑、历史数据显示、待办归属、权限文案、回放生命周期与导出。业务源码和已安装 App 未修改；不是最终全项目审查结论。

## 结论与问题表

**会后校正与交付链路存在内容不一致：用户修正原文后，旧纪要仍像有效结果一样展示和导出；待办已存负责人却没有显示；全文型历史记录不能在原文页阅读。** 这些都可以渐进修复，无需重写界面。

本批新增 8 项：P1 4 项、P2 4 项，无新增 P0。累计 26 项（P0 1 / P1 18 / P2 7）。第一批 BUG-001 的条件性人工校正丢失仍优先于本批问题。另有 1 项长逐字稿可访问性观察需验证，不计入上述数量。

| ID | 类型 | 级别 | 问题 | 证据 |
|---|---|---|---|---|
| BUG-016 | Bug / UX | P1 | 原文校正后，旧速览/纪要和导出没有过期标记 | 隔离 UI、实际 UI 导出、Store 探针 |
| BUG-017 | Bug / UX | P1（条件性） | 有全文但无分段的历史会话，原文页显示“没有内容” | 隔离 UI、持久化/导出对照探针 |
| UX-002 | UX / Bug | P1 | 待办负责人已在模型中保存，但速览页不展示 | 合成 owner 数据、UI 视觉/AX、导出对照 |
| UX-004 | UX | P1 | 缺麦克风权限被说成只缺说话人标注，未解释缺失麦克风声音 | 权限文案及采集代码；未撤销真实权限 |
| UX-003 | UX / Bug | P2 | 切换结果页静默丢弃未保存的编辑草稿 | 隔离 UI 实际输入/切页/返回 |
| UX-005 | UX / 可访问性 | P2 | 逐字稿编辑框无可访问性名称和句子上下文 | 实际编辑框 AX + 源码 |
| BUG-018 | Bug | P2 | 文件名按字符数裁剪，复杂 emoji 仍突破文件系统字节上限 | 真实临时文件写入探针 |
| BUG-019 | Bug / 性能 | P2 | 播放计时器强持有播放器，工作区离开时没有明确停止契约 | 合成静音 WAV + 弱引用探针、视图代码 |

## 验证范围与限制

- 已安装 App 只切换原文/速览/纪要并读取 AX/截图，最后保持原来的原文页；未编辑、导出、播放或重新整理真实会议。
- 独立 App 使用 GitHub 基线业务源文件，替换入口以注入临时 SessionStorage；独立 bundle ID `local.codex.MeetingScribeReview.batch3` 隔离偏好。源码见 [ReviewBatch3UIHarness.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/ReviewBatch3UIHarness.swift)，构建入口见 [build-batch-03-harness.py](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/build-batch-03-harness.py)。该夹具没有录音/云端调用/密钥保存需求；组件路径告警来自独立夹具未携带引擎，不作为产品问题。
- 本批 4 个隔离探针使用真实 Store、Exporter、AVAudioPlayer 和文件写入，warnings-as-errors 编译通过，全部捕获预期缺陷。**探针通过不是功能修复通过。** 探针归档为 [ReviewBatch3ReproTests.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/ReviewBatch3ReproTests.swift)，日志见 [batch-03-repro.log](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/batch-03-repro.log)，已从正式 Tests 目录移出。
- 合成 UI 的工具观察见 [batch-03-ui-observations.md](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/batch-03-ui-observations.md)，真实 UI 导出的合成文件见 [batch-03-ui-export.md](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/batch-03-ui-export.md)。保存面板首次将路径输入当文件名，合成文件一度写在 Documents，随后仅将该文件移入证据目录；未改动已有文件。
- 已检查并正常的对照：Escape 关闭设置、Cmd+Return 保存校正、无音频时的禁用与恢复入口、Markdown .md 导出、短逐字稿 AX 子节点。没有把缺少快捷键一概判作不可用，也没有把 plainText 配置直接判作扩展名错误。
- 未完成 VoiceOver 实际朗读、系统权限撤销/首次授权实测、各屏幕缩放档位、完整浅深色对比度测量、最低 macOS 15 和大规模性能测量。云端配置/密钥/传输安全留到下一批。

## 逐项证据、修复与验收

### BUG-016：人工校正后旧整理结果没有过期状态

| 字段 | 内容 |
|---|---|
| ID | BUG-016 |
| 类型 | Bug / UX |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [MeetingStore.swift:776](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:776)，updateTranscriptSegment；[WorkbenchView.swift:1013](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:1013)，速览；[MeetingExport.swift:31](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingExport.swift:31)，markdown |
| 问题描述 | 原文编辑更新分段、全文和 transcriptEditedAt，却保留旧 analysis，没有输入版本关联或过期标志。速览/纪要不消费编辑时间，导出也不提示旧结果基于修改前的材料。 |
| 证据 | 合成会议从“下周一交付”保存为“改为下周三交付”，原文显示“已人工校正 1 处”；速览、待办截止和纪要仍为下周一。实际 UI 导出同时含旧纪要与新原文，无过期提示。探针断言 analysis 与旧值完全相同、noticeMessage=nil。 |
| 影响 | 用户或收件人把旧决策、日期、金额、负责人当成校正后的结论执行；仅在原文页出现的校正标记不足以提醒阅读速览/纪要的人。 |
| 复现步骤 | 1. 使用有 6 段、足量文字、非本地规则模型来源的合成已完成会议。2. 修改涉及结论的第一句并保存。3. 打开速览/纪要并导出。4. 对照原文，确认旧日期仍呈现为当前结论。对应 testEditedTranscriptExportStillPresentsContradictoryOldMinutesWithoutWarning。 |
| 建议修复 | 保存原文 revision 或材料 hash，并在生成 analysis 时保存其 inputRevision；不匹配时保留旧结果但明确标“原文已更新，此结果待重新整理”。三页、复制、导出共用这一判据。用户主动重新整理成功后提交新版本；不要为消除过期标记自动向云端发送原文，也不要直接清空旧结果。 |
| 验证方式 | 校正日期、数字、否定意见后各结果页与导出均有过期状态；拒绝/无变化编辑不标过期；重整理失败/取消保留旧结果与过期提示；成功后 inputRevision 匹配才清标记。 |
| 是否 AI 生成典型问题 | 是：输入编辑实现完整，派生产物失效契约遗漏；作者来源不确定。 |

### BUG-017：全文型历史记录在原文页被隐藏

| 字段 | 内容 |
|---|---|
| ID | BUG-017 |
| 类型 | Bug / UX |
| 严重级别 | P1 严重（transcriptText 非空且 transcriptSegments 为空时） |
| 置信度 | 高；用户存量数据中该形态的数量未统计 |
| 位置 | [WorkbenchView.swift:1574](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:1574)，WorkbenchOriginalDocument；[MeetingStore.swift:218](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:218)，reloadSessions；[MeetingExport.swift:281](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingExport.swift:281)，transcriptAppendix 的全文回退 |
| 问题描述 | 原文页只看分段数组，为空就写“转写还没有内容”，没有读 transcriptText 的回退。材料门禁也只评估分段，进一步可能显示“没有识别到发言”。导出却支持全文回退，说明同一合法数据形态在各入口不一致。 |
| 证据 | UI 合成夹具有完整 transcriptText，原文页显示“转写还没有内容”，速览引导到原文确认。探针保留 620 字全文，加载后全文逐字不变、分段为空、生成 no-speech 材料状态；Exporter 可以导出那 620 字。 |
| 影响 | 用户无法在核心原文界面阅读已经保存的全文，误以为未转写，可能进行不必要重试；这不是磁盘内容被删除。 |
| 复现步骤 | 1. 临时 ready 会议写非空 transcriptText、空 transcriptSegments。2. 打开原文。3. 观察空态。4. 用同会话导出，与磁盘全文对照。对应 testLegacyTextSurvivesButMaterialGateTreatsItAsNoSpeech。 |
| 建议修复 | 分段为空但全文非空时以普通可选择文本展示，明确无时间锚/分段编辑能力；空态必须在两个文本来源均为空时才出现。材料门禁与旧分析修补也应识别全文来源，不能按空数组宣称没有发言；需时间锚时让用户另行选择重新转写，先保留全文。 |
| 验证方式 | 分段版、仅全文版、全文空白、完全空、旧 schema 各一场。全文版可以阅读/复制/导出，不伪造时间戳、不被修补清空，重试失败不损失原文。 |
| 是否 AI 生成典型问题 | 是：新分段界面完成，但兼容回退只在导出实现；作者来源不确定。 |

### UX-002：待办负责人保存了却没显示

| 字段 | 内容 |
|---|---|
| ID | UX-002 |
| 类型 | UX / Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [WorkbenchView.swift:1910](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:1910)，WorkbenchActionDocumentRow；[WorkbenchView.swift:1151](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:1151)，actionSection；[MeetingModels.swift:771](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingModels.swift:771)，ActionItem.owner |
| 问题描述 | 待办行渲染截止、优先级与置信度，完全不消费 owner。若任务标题未重复负责人，用户在待办的唯一展示页无法知道谁负责。 |
| 证据 | 夹具 label=“交付报价单”、owner=“审查甲”；UI 视觉和 AX 均只有任务、截止、优先级、把握。相同会话实际导出带“负责人 审查甲”。源码注释声称负责人跟随行尾，实际没有对应分支。 |
| 影响 | 核心“谁做什么”信息缺失，多人协作需要翻纪要或导出来查，责任归属容易遗漏。 |
| 复现步骤 | 1. 构造 owner 单独存值、label 不带姓名的 ActionItem。2. 打开速览待办。3. 与 JSON/导出对照。 |
| 建议修复 | 在行内稳定位置展示裁剪空白后的 owner，允许长姓名换行，并给读屏明确“负责人：…”；nil/空白不猜人名。把 UI 与导出的 owner 格式化规则收为共享纯函数。 |
| 验证方式 | 有负责人、nil、空白、多人和超长姓名分别检查；视觉/AX/导出一致，姓名不能仅存在 help 悬停文案中，不能被优先级徽标挤出。 |
| 是否 AI 生成典型问题 | 是：模型与导出字段已接通，展示层漏接，注释与实现不符；作者来源不确定。 |

### UX-004：缺麦克风权限的后果说明不完整

| 字段 | 内容 |
|---|---|
| ID | UX-004 |
| 类型 | UX |
| 严重级别 | P1 严重 |
| 置信度 | 高（文案与音源契约）；具体设备/系统录音效果需验证 |
| 位置 | [MeetingModels.swift:398](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingModels.swift:398)，CaptureReadiness.microphoneCaveat；[WhisperPipeline.swift:276](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift:276)，MixedRecordingSession.start |
| 问题描述 | 文案说“没有麦克风权限：录音照常，但原文不会区分我方/对方”，把降级解释为仅缺标签。实际采集代码自身明确记录“我方那一路不会有任何样本”，因此不能保证收录本机麦克风发言。 |
| 证据 | 文案在 MeetingModels.swift:401；start 的注释与日志明确 `.microphone` 为 0 帧，却继续启动系统音频采集。没有把真实系统权限关闭来制造丢录。系统声偶然回传麦克风的设备场景不在此作确定性假设。 |
| 影响 | 用户可能认为全文仍完整，只是无归属标签，录完才发现本机发言没有录到；在耳机会议中尤其需要说明可能只有系统声音。 |
| 复现步骤 | 代码确认；实机待验证：在隔离录音流程拒绝麦克风权限、保留系统音频权限，观察提示后录制两路不同测试音，对照输出音源与文字完整性。 |
| 建议修复 | 提示“未获麦克风权限，无法采集本机麦克风；本次可能只录到系统声音，也无法生成完整双路归属”。未询问与已拒绝分别给授权/系统设置路径，若允许继续则明确“仅录系统声音”，录音中和结果中保存降级标记。 |
| 验证方式 | 未询问、拒绝、受限制、正常授权分别验证；不应把麦克风权限不足描述为纯显示问题。拒绝状态继续录音时输出和导出标明录制来源，用户能恢复授权再开新录音。 |
| 是否 AI 生成典型问题 | 是：技术日志知道缺音源，用户提示却缩减成缺标签；作者来源不确定。 |

### UX-003：切页静默丢弃未保存草稿

| 字段 | 内容 |
|---|---|
| ID | UX-003 |
| 类型 | UX / Bug |
| 严重级别 | P2 一般 |
| 置信度 | 高（Tab 切换复现）；关窗和其他导航路径需分别回归 |
| 位置 | [WorkbenchView.swift:921](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:921)，结果页 switch；[WorkbenchView.swift:1568](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:1568)，editingSegmentID；[WorkbenchView.swift:1964](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:1964)，行内 draft |
| 问题描述 | 编辑状态与草稿仅在原文子视图保存；切到速览/纪要会销毁该分支，无保存提示或草稿恢复。回到原文是旧正文、只读态。 |
| 证据 | 输入“审查草稿：改为周三交付，尚未保存。”后保存按钮启用；点速览直接离开，回原文仅显示最初的周一文本。没有点击保存或放弃。 |
| 影响 | 用户对照纪要核查原文时丢失未提交的输入，需重新修改；不声称已保存文本丢失。 |
| 复现步骤 | 1. 原文点铅笔并改一段。2. 不保存，切速览。3. 返回原文。4. 再编辑，草稿已不在。 |
| 建议修复 | 将编辑草稿提升到按 sessionID/segmentID 管理的工作区状态，切 Tab 可恢复；或在离开时提供保存/放弃/继续编辑。统一处理切会议、启动任务、关窗，避免只补某颗 Tab 按钮。 |
| 验证方式 | 有变化、无变化、空白无效输入、保存失败分别导航；有变化草稿不静默丢失。确认保存失败后仍留原页和草稿；明确放弃后才清理。 |
| 是否 AI 生成典型问题 | 是：保存 happy path 完整，离开路径的输入保护缺失；作者来源不确定。 |

### UX-005：编辑输入框没有可访问性名称

| 字段 | 内容 |
|---|---|
| ID | UX-005 |
| 类型 | UX / 可访问性 |
| 严重级别 | P2 一般 |
| 置信度 | 高（AX 名称为空）；具体 VoiceOver 朗读流程需实测 |
| 位置 | [WorkbenchView.swift:2110](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:2110)，WorkbenchTranscriptDocumentRow.editor |
| 问题描述 | `TextField("", text: $draft, axis: .vertical)` 没有 accessibilityLabel。保存与取消按钮有名称，但聚焦字段本身只提供文本值，不明确这是哪一时间/来源的逐字稿编辑。 |
| 证据 | 合成 UI AX：`64 text field (settable) 审查甲下周一交付报价单。`，没有 Description；相邻保存按钮有 `Description: 保存这一句`。源码无字段标签或共享语义分组。 |
| 影响 | 使用读屏/语音控制时缺少稳定字段名称，多段文本相似或清空字段后难以确认编辑对象。此项不表示键盘保存不可用，Cmd+Return 已验证正常。 |
| 复现步骤 | 1. 在合成原文打开一段编辑。2. 读取 AX 字段名称与值。3. 核对值存在、名称空；直接 VoiceOver 朗读作为后续验收。 |
| 建议修复 | 加明确 accessibilityLabel，如“编辑 00:06 对方的逐字稿”，值仍由 TextField 自身提供；必要时补“Cmd+Return 保存，Escape 取消”的提示。空文本也保留名称，名称不重复整段正文。 |
| 验证方式 | 空/非空值、两段相同正文、不同 speaker 及时间均有唯一可理解的名称；VoiceOver 和语音控制可定位字段，快捷键与焦点顺序保持正常。 |
| 是否 AI 生成典型问题 | 是：视觉编辑器与图标标签完成，输入的语义标签遗漏；作者来源不确定。 |

### BUG-018：字符长度限制不保证合法文件名字节数

| 字段 | 内容 |
|---|---|
| ID | BUG-018 |
| 类型 | Bug |
| 严重级别 | P2 一般 |
| 置信度 | 高 |
| 位置 | [MeetingExport.swift:189](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingExport.swift:189)，sanitizedTitle；[MeetingStore.swift:451](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:451)，导出默认文件名 |
| 问题描述 | `.prefix(60)` 限制 Swift Character 数，不能保证 255 UTF-8 字节。一个组合 emoji/grapheme 可能有很多字节，因此合法输入仍生成无法写入的默认文件名。 |
| 证据 | 标题为 60 个家庭 emoji，fileName 返回 74 个 Character、1514 UTF-8 字节；真实临时文件写入失败。普通中文限制测试通过不足以涵盖 Unicode 边界。 |
| 影响 | 这类标题的导出需要用户手工缩短名称，否则面板或写入拒绝。不是路径遍历，也没有证据证明普通标题导出普遍失败。 |
| 复现步骤 | 1. 标题重复组合 emoji 60 次。2. 用实际 MeetingExporter.fileName 得默认名。3. 统计 utf8.count 并写临时文件。对应 testEmojiTitleExceedsFilesystemByteLimitDespiteCharacterLimit。 |
| 建议修复 | 为日期前缀、分隔符和 `.md` 预留字节预算，按完整 Character 累加 UTF-8 字节直至上限；单个字符超预算时跳过/回退，保留非空安全名。不要用截断原始 UTF-8 Data 的办法破坏字符编码。 |
| 验证方式 | 中文、单 emoji、ZWJ 家庭 emoji、组合音标、仅非法字符与单个超长 grapheme 均覆盖；最终 utf8.count<=255 且可以真实写入。 |
| 是否 AI 生成典型问题 | 是：注释声称处理字节上限，实现却只处理字符数量；作者来源不确定。 |

### BUG-019：播放器计时器没有覆盖离开与失败生命周期

| 字段 | 内容 |
|---|---|
| ID | BUG-019 |
| 类型 | Bug / 性能 |
| 严重级别 | P2 一般 |
| 置信度 | 高（对象保留已复现）；UI 销毁/播放失败的具体表现需回归 |
| 位置 | [AudioPlayback.swift:55](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/AudioPlayback.swift:55)，togglePlayback；102，startTimer；[WorkbenchView.swift:677](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:677)，工作区生命周期 |
| 问题描述 | 重复 target Timer 强持有 self；播放器也保存 timer。视图在加载/切会话时停止旧播放器，但工作区整体消失没有 stop。play() 结果没检查就启动 timer，updatePlayback 即使不在播放也不使其失效。 |
| 证据 | 合成 10 秒静音 WAV，实际启动播放后释放所有外部强引用，弱引用仍存在且 isPlaying=true；显式 stop 后对象释放。工作区无 onDisappear 清理。自然播放结束的 delegate 会停 timer，因此不声称所有播放都会永久泄漏。 |
| 影响 | 工作区离开/窗口关闭时，可能仍播放到音频结束且持有音频资源；若 play 失败或异常未走完成回调，重复 timer 缺乏停止保证。完整 App 关窗行为尚未故障注入。 |
| 复现步骤 | 1. 加载隔离静音 WAV 并播放。2. 保留弱引用，释放唯一外部强引用。3. 对象仍存在且播放。4. 显式 stop 后确认释放。对应 testPlaybackTimerRetainsOwnerUntilExplicitStop。 |
| 建议修复 | 在工作区整体离开时明确 stop（不要把切 Tab 当成退出工作区）；计时器改为弱引用闭包或独立生命周期对象，避免仅依赖 deinit 打破自身循环。只有 play() 成功才建 timer，播放失败/解码错误即时清理与报错。 |
| 验证方式 | 播放/暂停/自然结束/失败启动/解码错误、工作区移除与窗口关闭分别检查；不再播放时无重复 timer，明确停止后弱引用释放。切 Tab 仍允许预期的连续回放，切会议不同时播放两个源。 |
| 是否 AI 生成典型问题 | 是：常用 Timer 写法接通正常播放，资源归属与异常收尾遗漏；作者来源不确定。 |

## 可访问性待验证观察（不计入已确认数量）

| 字段 | 内容 |
|---|---|
| ID | VERIFY-UX-001 |
| 类型 | UX / 可访问性（需验证） |
| 严重级别 | 暂拟 P1：若 VoiceOver 同样无法读取核心原文 |
| 置信度 | 中：工具观察稳定，真实读屏后果未确认 |
| 位置 | WorkbenchOriginalDocument 的非惰性 VStack/ForEach，WorkbenchView.swift:1577；已安装原文页与 1000 段合成夹具 |
| 问题描述 | 长逐字稿视觉有文本/铅笔，可访问性快照的滚动区却无子节点；6 段对照正常。尚不能区分 SwiftUI/系统 AX 行为与 cua_repl 的遍历/超时限制。 |
| 证据 | 1000 段夹具点原文返回仅 scroll area，滚动后仍无变化，截图可见第 10–19 句。安装 App 也有同样观察。 |
| 影响 | 若真实读屏同样受影响，使用 VoiceOver 的用户不能阅读/校正长会议；该后果目前需验证。 |
| 复现步骤 | 1. 构建隔离 UI。2. 选择 1000 段夹具并进原文。3. 用 VoiceOver 实际导航及 Accessibility Inspector 检查可见行。4. 与 6 段夹具及 CUA 快照对照。 |
| 建议修复 | 先定位可访问性生成与采集限制；若应用节点构建确实受长度影响，再试按行明确 contain 语义和惰性容器/分页。不能仅加全文 accessibilityLabel 替代行内编辑控件，也不能未经回归换 LazyVStack 了事。 |
| 验证方式 | 6/100/1000 段，在首屏、中部、末尾均可朗读文本、时间、来源，并定位相应修改按钮；焦点移动与滚动一致。 |
| 是否 AI 生成典型问题 | 不确定，根因尚未定位。 |

## 修复顺序与回归清单

| 顺序 | 可执行工作 | 验收门 |
|---|---|---|
| 0 | 先完成既有 BUG-001 旧版本保护、BUG-008/009 文本忠实性与录音生命周期修复 | 不能让用户校正后再被重试/清洗丢弃 |
| 1 | BUG-016：建立原文 revision 与整理输入 revision，统一页面/导出过期提示 | 周一改周三后，不再交付无提示的旧结论 |
| 2 | UX-002 / UX-004：补负责人展示和真实缺音源后果文案 | 任务归属可见；权限不足不伪装成仅缺标签 |
| 3 | BUG-017：全文回退与材料门禁兼容 | 仅全文记录可读可导出，原件不动 |
| 4 | UX-003 / UX-005：草稿跨导航保护与明确字段标签 | 输入不静默丢弃；空字段也能定位 |
| 5 | BUG-018 / BUG-019：Unicode 文件名预算与播放器生命周期 | 极端合法标题能写盘，离开/失败后无孤立播放 |
| 6 | VERIFY-UX-001：VoiceOver/Inspector 对照定位 | 确认根因再升级为正式缺陷或归为工具限制 |

1 天内候选（估算）：负责人展示、权限文案、编辑框标签、仅全文显示回退、Unicode 字节裁剪和基础 workspace stop。revision 失效机制、跨导航草稿以及长逐字稿可访问性定位应独立排期，不能因补丁短就省掉回归。

字节预算最小示例，应用在过滤非法字符、折叠分隔符之后；还需处理“第一个 Character 本身就超预算”的回退：

```swift
func prefixWithinUTF8Budget(_ text: String, maxBytes: Int) -> String {
    var result = ""
    var used = 0
    for character in text {
        let value = String(character)
        let bytes = value.utf8.count
        guard used + bytes <= maxBytes else { break }
        result += value
        used += bytes
    }
    return result
}
// 255 - 日期及分隔符的 UTF-8 字节数 - ".md" 的字节数；空结果回退安全默认名。
```

上述是修复建议与示例，不是已应用补丁。下一批建议检查云端端点、密钥、网络失败与重定向、本地文件/进程边界和分发安全，再做性能及维护性收尾。
