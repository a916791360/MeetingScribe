# MeetingScribe 审查报告 · 第 2 批

审查日期：2026-10-06（Asia/Shanghai）。源码基线仍为 GitHub `main` 的 `bd80e302b88622bb435eb73b47b34b847fb3f86f`，版本 `0.11.1` / build `21`。范围：录音样本落盘、双路转写、清洗与去重、分块边界、取消、删除和异常恢复。此批属于功能与 Bug 审查，不代表实际录音设备兼容性或全部安全审查已完成。

## 结论与高优先级问题

**核心风险从“能否生成结果”延伸到了“结果是否忠实于原音频”：双路时间位置、说话人、否定意见和边界句子都可能在处理时改变或遗漏。** 另有任务归属缺陷：旧任务收尾会改写新任务状态，异常子进程无法保证取消完成。

新增 10 项 P1，没有新增已确认的 P0。第一批 BUG-001 的条件性人工校正数据丢失仍应最先修。累计问题 18 项（P0 1 / P1 14 / P2 3），其中包含第一批的架构建议。这个数量是两批检查结果，不是全项目问题总数。

| ID | 级别 | 问题 | 本批证据 |
|---|---|---|---|
| BUG-006 | P1 | 落盘忽略样本时间戳，音轨缺口被压缩，双路不再保证对齐 | 合成 CMSampleBuffer + 真实文件写读 |
| BUG-007 | P1 | 音轨中途失败仍被当作可用的完整双路输入 | Recorder 故障复现 + 结果选择代码；完整系统事件未实测 |
| BUG-008 | P1 | 清洗跨说话人合并/去重，对方发言可能标成我方或消失 | 实际 Cleaner 的合成对话复现 |
| BUG-009 | P1 | 串音去重把“可以上线”与“不可以上线”当同句 | 实际 Merger 的合成反例复现 |
| BUG-010 | P1 | 双路检查点只保存当前一路，第二路覆盖第一路已完成内容 | 实际 Store + 注入 CLI 输出/失败复现 |
| BUG-011 | P1 | 删除旧任务后，其晚到收尾将新任务标成空闲 | 实际 Store/进程包装器 + 可控 CLI 复现 |
| BUG-012 | P1 | CLI 拒绝 SIGTERM 时，取消无法收尾，超时也缺退出保证 | 实际进程包装器 + 信号故障注入 |
| BUG-013 | P1 | 删除正在录音的会议未先停止录音器 | 代码确定；真实系统采集后果需实机验证 |
| BUG-014 | P1 | 采集异常仅缓存，主动停止前不向 Store/界面报告 | 代码确定；系统错误触发需实机验证 |
| BUG-015 | P1 | 跨分块长句的完整后半段被按起点丢弃 | 实际分块归属函数 + 合法构造输出复现 |

## 已执行验证及边界

- 第一批已有基线：Swift 290 项，1 项因缺云端评测凭据跳过，0 失败；Python 28 项及 7 个合成语料检查通过。本批没有改业务源码，因此没有重复执行无变化的全量检查。
- 本批新增 8 个复现探针，7 个一起运行，边界探针新增后单独运行；均编译通过（warnings-as-errors），成功捕获各自所断言的缺陷。**这些探针断言当前错误行为存在，“通过”不表示功能修复完成。**
- 探针源码：[ReviewBatch2ReproTests.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/ReviewBatch2ReproTests.swift)。主日志：[batch-02-repro.log](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/batch-02-repro.log)。边界日志：[batch-02-boundary.log](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/batch-02-boundary.log)。
- 时间戳与轨道失败测试使用真正 AVAudioFile/CMSampleBuffer；双路转写和任务交错测试使用 App 的 Store/进程包装器，外部 CLI 被可控制输出和信号的本地程序替代。没有据此宣称真实 whisper 的转写准确率或实际设备错误发生率。
- 转写探针运行在随机临时数据目录，输入为合成 PCM，显式使用本地规则整理。测试前后保存/恢复相关 UserDefaults 键；没有发送云端请求、读取真实会议内容或修改实际钥匙串。
- 拒绝 SIGTERM 的测试进程由探针强制结束并等待任务完成。临时探针已从正式 Tests 目录移出，源码与日志归档在此。
- 尚未在真实会议中故意删除活动录音、切换设备或撤销权限；BUG-013/014 的实际采集表现仍需隔离实机验证。没有重打包或改写已安装 App，所有修复仍待执行。

## 逐项问题表

### BUG-006：写盘丢失音频时间位置

| 字段 | 内容 |
|---|---|
| ID | BUG-006 |
| 类型 | Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高（缺口压缩已复现）；实际双路首包偏移与中断频率需验证 |
| 位置 | [AudioTrackRecorder.swift:77](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/AudioTrackRecorder.swift:77)，append；144–201，write；[WhisperPipeline.swift:328](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift:328) 的“同一个时钟天然对齐”注释 |
| 问题描述 | 样本被按到达顺序连续写入 AVAudioFile，未读取 presentationTimeStamp、补静音、保存起始偏移或识别时间缺口。同一采集时钟只有在时间信息被保留时才能保证双路文件对齐；延迟首包或缺包后，某一路时间会被压缩。 |
| 证据 | 两个合法 0.1 秒缓冲的 PTS 分别为 10.0 和 12.0；写后文件只有 3200 帧 / 0.2 秒，未覆盖首包到末包的 2.1 秒，也没有 failureReason。write 只调用 file.write(from: buffer)，完全不消费 PTS。 |
| 影响 | 时间锚跳回放偏移、两路发言顺序或重叠关系判断错误；串音去重和说话人归属受影响。原始 MOV 被保留，故本项不声称音频原件已永久丢失。 |
| 复现步骤 | 1. 用同格式创建 PTS=10.0/12.0 的两个 1600 帧、16kHz 缓冲。2. append 两次并 finish。3. 读取 CAF 帧数与时长，观察 0.2 秒。探针 testSampleTimestampGapIsRemovedFromRecordedFile。 |
| 建议修复 | 在会话层提供两路共同时间原点；Recorder 按 PTS 计算目标帧位置，首包延迟与间隙补零，重复/重叠帧裁剪或明确失败。若选择保留紧凑文件，必须存完整的时间映射并在转写结果中重映射，不能仅加一个固定偏移解决中途缺口。 |
| 验证方式 | 双路不同首包时间、2 秒缺口、乱序/重复包、长期连续样本及不同采样率均验证。对应同一真实时刻的段在合并后位置一致；与混合原件回放一致；不支持的缺口处理应显式降级。 |
| 是否 AI 生成典型问题 | 是：采样 API 接通，但时间契约遗漏；AI 作者身份不确定。 |

### BUG-007：失败的半条音轨仍参与完整转写

| 字段 | 内容 |
|---|---|
| ID | BUG-007 |
| 类型 | Bug / UX |
| 严重级别 | P1 严重 |
| 置信度 | 高（失败标记和选择条件）；实际系统设备变化后果需验证 |
| 位置 | [AudioTrackRecorder.swift:94](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/AudioTrackRecorder.swift:94)、114、124；[WhisperPipeline.swift:427](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift:427)，makeResult；[MeetingStore.swift:1575](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:1575)、1633 |
| 问题描述 | 轨道写入中途出错后停止接收后续样本，但 didWriteAudio 仍为 true。makeResult 只看是否写过帧，不看 failureReason、结束状态或覆盖时长，因而会交出截断的 CAF。两路文件都存在就进入双路转写，未利用完整 MOV 补偿缺失后半场。 |
| 证据 | 先写 16kHz 片段，再输入 48kHz：Recorder 有 failureReason，但 didWriteAudio=true，留下只有首段的文件。makeResult 对这一状态返回非 nil trackURL；失败原因仅进入诊断日志。 |
| 影响 | 发生音频设备/格式变化或写盘错误后，某一方后续发言可能缺失；最终结果仍可能 ready，用户不知道产物不完整。探针验证的是轨道截断与选择标记，并未真正触发 ScreenCaptureKit 设备变化。 |
| 复现步骤 | 1. 同 Recorder 先 append 合法 16kHz PCM。2. 改用 48kHz PCM。3. finish，确认 failureReason 非空但 didWriteAudio 为 true。4. 核对 makeResult 只消费该 true。探针 testFailedTrackStillLooksUsableToResultSelection。 |
| 建议修复 | 区分“有帧”和“完整可用”，产出包含失败原因/覆盖范围的 TrackResult。轨道失败时降级至已验证的混合原件或补转缺失范围，明确展示双路降级/内容不完整；验证补偿完成前不删除仅有的轨道证据。 |
| 验证方式 | 格式切换、写满磁盘、单路丢包、正常静音与 0 帧分别注入。截断轨道不能冒充完整；完整混合原件可用时保住全文；降级提示与实际缺失范围一致。 |
| 是否 AI 生成典型问题 | 是：把“曾经成功”误用作“完整成功”；AI 来源不确定。 |

### BUG-008：后处理无视说话人边界

| 字段 | 内容 |
|---|---|
| ID | BUG-008 |
| 类型 | Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [TranscriptCleaner.swift:132](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/TranscriptCleaner.swift:132)，collapseRepeats；235–259，mergeBySentence；[MeetingStore.swift:1241](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:1241) 在双路合并后调用 clean |
| 问题描述 | 并句不检查 speaker 或间隔，保留首段 speaker；复读折叠也不检查 speaker 和时间。因此已正确标记的两人对话被重新压成一人的发言，或者第二人的独立确认被删掉。 |
| 证据 | local“这笔预算我们还没确认”（无句号）+ remote“我明天提供最终报价。”清洗后为一条 local 段，包含 remote 的承诺。另一个反例是两人相隔 20 秒说“这个方案可以上线。”，最终只剩一段。 |
| 影响 | 待办负责人可能被模型归给错误的一方；原文页不再忠实保存两人表达；证据段、时间范围和对话顺序被改变。 |
| 复现步骤 | 1. 构造不同 speaker 的两段，第一段不以句末符结束。2. 调 TranscriptCleaner.clean。3. 检查段数 1、speaker 仍 local。4. 用相同句子、不同 speaker、相隔 20 秒重复，确认仍被折叠。探针 testCleaningMergesDifferentSpeakersIntoOneLocalSegment。 |
| 建议修复 | 并句必须保持 speaker 一致并限制可解释的时间邻接；复读判断需保留说话人/来源/实际发生时间。跨人确认或真实重复应保留，疑似引擎幻觉用单独标记和可恢复原段处理。 |
| 验证方式 | 我方提问/对方承诺、两人重复确认、同人远隔重复、短相邻碎段、重叠双人发言都覆盖。清洗前后的真实归属不变，独立发言不消失，时间锚保持可核对。 |
| 是否 AI 生成典型问题 | 是：新增 speaker 后旧清洗代码未同步语义；AI 来源不确定。 |

### BUG-009：相反意见被误判为串音

| 字段 | 内容 |
|---|---|
| ID | BUG-009 |
| 类型 | Bug / AI生成代码 |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [TranscriptMerger.swift:120](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/TranscriptMerger.swift:120)、143–162，resolve/isSameSpeech/containment |
| 问题描述 | 相似度只统计共享字符，阈值 0.6，并允许较短字符串完全包含在长句中。增加“不”这样的否定词不会降低包含比例到阈值以下，相反意见被视为同一句；随后按置信度只留下一个人的话。 |
| 证据 | 重叠段：“这个方案可以上线。”（0.95）与“这个方案不可以上线。”（0.9），实际 merge 只返回肯定句；反对意见消失。不是仅缺少标点，而是实际决策含义相反。 |
| 影响 | 用户可能把争议误读为达成一致，后续速览/纪要/待办基于不完整且偏向一方的原文生成。 |
| 复现步骤 | 1. local 时间 0–3 秒、肯定句。2. remote 时间 0.1–3.1 秒、否定句。3. 调 TranscriptMerger.merge。4. 结果只有 local 肯定句。探针 testCrosstalkDeduplicationDeletesTheOppositeDecision。 |
| 建议修复 | 最小保护是只去重严格归一化相同、且有可靠声源证据的回声副本；对否定、数字、时间、主体不同的文本保留两条。扩大模糊去重前建立反例集，不能仅提高字符阈值——本例包含比例可达 1。 |
| 验证方式 | 可以/不可以、同意/不同意、15万/50万、今天/明天、我方/对方承担等成对反例必须保留；真实同句串音仍可正确处理且不伪造归属。 |
| 是否 AI 生成典型问题 | 是：用表面字符串相似替代语义一致，happy path 测试掩盖错误。 |

### BUG-010：双路检查点覆盖完整的一路

| 字段 | 内容 |
|---|---|
| ID | BUG-010 |
| 类型 | Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [MeetingStore.swift:1650](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:1650)，transcribeDualTracks；1718、1764–1771，transcribeTrack |
| 问题描述 | 两路结果在内存 bySpeaker 中累积，但每个块落盘时把 session.transcriptSegments 直接设为当前一路的 segments。开始保存第二路后，盘上的第一路内容被覆盖，speaker 也尚未标记。失败/退出时“已完成内容”不是双路已完成内容的合集。 |
| 证据 | 构造 601 秒两路 WAV，让 CLI 成功输出我方两块、对方第一块，在对方第二块退出 42。最终 failed 的 session.json 仅含“对方第一段内容”，无“我方已经完成的内容”，speaker 全 nil。分块 JSON 仍可能在磁盘，故不是音频原件永久丢失。 |
| 影响 | 失败界面无法展示已经完成的完整部分，恢复证据与进度不一致；启动恢复的双路路径从头重跑，不利用已产出的两路检查点，增加重复等待。 |
| 复现步骤 | 1. 临时会话带 local.wav/remote.wav，各 601 秒。2. 注入 CLI 使第二路第二块失败。3. 调实际 retryProcessing 并等待 failed。4. 读 JSON，观察只剩第二路首块。探针 testSecondTrackCheckpointOverwritesTheCompletedFirstTrack。 |
| 建议修复 | 按 source/speaker 分别持久化 segments、已完成块和时间覆盖范围；可见逐字稿由两路已完成片段合并派生，每块保存应保留另一来源。保存错误必须向上抛，不用 try? 掩盖。恢复按两路独立检查点续跑，并明确标记部分结果。 |
| 验证方式 | 在两路每个块之前/之后注入失败与退出，重启后可见所有已完成块及正确 speaker。续跑只处理未完成块，结果与一次成功处理一致；盘满时明确失败而非显示未保存结果。 |
| 是否 AI 生成典型问题 | 是：单路检查点实现被复用到双路，存储语义未同步改变。 |

### BUG-011：旧任务收尾破坏新任务状态

| 字段 | 内容 |
|---|---|
| ID | BUG-011 |
| 类型 | Bug / 架构 |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [MeetingStore.swift:1060](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:1060)，deleteSession；1365–1403，failProcessing/cancelFinishedProcessing；[WhisperPipeline.swift:792](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift:792)、844，LocalProcessRunner.run 清理 |
| 问题描述 | 删除旧任务取消异步工作后立即允许新任务开始；旧 catch/收尾没有核对任务 token，就清空全局 busy、processingTask 与 activeSessionID。进程包装器也会在旧 run 的 defer 中无条件清 activeProcess，可能清掉新进程句柄。 |
| 证据 | A 的 CLI 延迟响应 SIGTERM；删除 A，开始 B，B 的 CLI 已运行且 session.status=processing；释放 A 后，Store.isProcessing 变成 false，而 B 仍未结束。最后放行 B 仍可完成 ready，证明当时不是 B 已完成。 |
| 影响 | UI 错误显示空闲、停止按钮失去作用、再次允许录音/导入；实际运行与界面状态分离。旧异步 cancel 调用也可能作用到新进程，需要同一轮归属保护。 |
| 复现步骤 | 1. 开始 A，等待测试 CLI 启动。2. 删除 A，立即开始 B。3. 等 B 启动但保持阻塞。4. 只放行 A 的退出。5. 检查 B 的盘上状态仍 processing，而 Store 已 false。探针 testDeletedOldTaskClearsNewTaskBusyState。 |
| 建议修复 | 为每个操作与每次子进程 run 分配唯一 ID；旧操作可处理自己资源，但不能更新新操作全局状态。cancel 应明确指定目标 run，不使用共享“当前进程”取消任意对象。取消/删除可先进入 cancelling，再等对应工作收尾；若允许新工作并行，需分离完整上下文。 |
| 验证方式 | A 正常/失败/取消晚到，B 已开始；A/B 交错删除；取消后立即重试与重新整理，都用可控屏障测试。B 状态不被 A 改写，取消只终止指定进程，旧任务清理不删新句柄。 |
| 是否 AI 生成典型问题 | 是：共享状态的异步回调没有任务归属校验；AI 来源不确定。 |

### BUG-012：超时和取消没有进程退出上限

| 字段 | 内容 |
|---|---|
| ID | BUG-012 |
| 类型 | Bug |
| 严重级别 | P1 严重（外部 CLI 无法正常退出时触发） |
| 置信度 | 高（SIGTERM 反例）；未等待真实 12 分钟计时器触发 |
| 位置 | [WhisperPipeline.swift:823](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift:823)、841、864，LocalProcessRunner.run/cancel；[MeetingStore.swift:1507](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:1507)，transcribeChunkWithTimeout |
| 问题描述 | 取消只发 terminate/SIGTERM，continuation 要等 terminationHandler。没有宽限期、强制结束或可确保完成的收尾协议。超时 task group 的 cancelAll 也要等子任务完成，不能凭计时器抛错保证整体调用及时返回。 |
| 证据 | 合成 CLI 明确忽略 SIGTERM；取消 Task 并调用 runner.cancel 后，300ms 检查进程仍活着，任务仍等待。之后探针发送 SIGKILL 才能结束。持续等待结论由无限 CLI 与无退出上限代码共同支持，而不是声称实测了无限时间。 |
| 影响 | 用户长时间停在“正在停止处理”，无法开始下一场；预设超时不能在此条件下释放状态和资源。挂住 CLI 也可能持续占 CPU/内存。 |
| 复现步骤 | 1. 临时 CLI 安装 SIGTERM 忽略处理器后循环。2. 用实际 WhisperCLIRunner 执行。3. task.cancel 并 runner.cancel。4. 检查仍活着且任务未完成；测试自行强制结束以清理。探针 testCancellationDoesNotFinishIfCLIRejectsSIGTERM。 |
| 建议修复 | 对自己启动的确切进程先请求终止，短宽限期后若仍活着再强制结束，并等待/reap；保留进程身份与有锁的一次性 continuation 完成状态，防重复恢复。考虑进程组/子进程边界，退出流程必须在有限时间内完成。 |
| 验证方式 | CLI 正常退出、立即退出、忽略 TERM、TERM 时延迟退出、启动前取消、结束与取消竞态都验证。超过取消时限应结束对应进程并清状态；无遗留子进程，无 continuation 双重恢复。 |
| 是否 AI 生成典型问题 | 是：计时器与 cancel 调用表面齐全，却未保证底层工作可取消。 |

### BUG-013：删除活动录音未停止采集

| 字段 | 内容 |
|---|---|
| ID | BUG-013 |
| 类型 | Bug / 安全（录音生命周期） |
| 严重级别 | P1 严重 |
| 置信度 | 高（没有 stop 调用）；中（删除后真实系统采集表现需验证） |
| 位置 | [MeetingStore.swift:1060](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:1060)，deleteSession；stopRecording:324；[WorkbenchView.swift:248](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:248) 的会议菜单始终提供删除 |
| 问题描述 | 活动会话是 recording 时，deleteSession 只取消处理任务与录音上限计时，把 isRecording=false，再删除文件目录。它没有停止 mixedSession/microphoneSession，也没有释放这些录音器引用。后续 stopRecording 又因 isRecording=false 被 guard 拒绝。 |
| 证据 | 删除分支只有 transcriber.cancel/transcoder.cancel；实际录音由 MixedRecordingSession 的 stream 持有，停止需要 stop()/stopCapture。录音期间 processingTask 通常为空，因此取消处理任务不能替代停止采集。 |
| 影响 | 可能在 UI 显示空闲、目录已删除之后继续使用屏幕/麦克风采集资源；文件收尾失败，后续录音重入。是否持续实际采集、持续多久，需在隔离系统录音中验证。 |
| 复现步骤 | 需实机验证：1. 隔离数据根开始短合成/环境录音。2. 从会话菜单删除当前录音。3. 检查系统采集指示与进程/文件句柄是否消失。4. 检查后续停止/新录音行为。本批未对用户真实录音执行删除。 |
| 建议修复 | 活动 recording/preparing 的删除要先完成对应录音器取消/stop 与文件关闭，再删除数据并更新 UI；失败时保留明确的 stopping/error 状态。最小临时保护是禁用活动录音的删除入口，并提供“停止后删除”。 |
| 验证方式 | 开录准备期、稳定录音、正在停止及停止报错分别尝试删除。确认采集终止、句柄关闭、取消上限计时不留下孤立录音器，新录音不会与旧采集并存。 |
| 是否 AI 生成典型问题 | 是：删除与转写取消共用分支，遗漏真实录音对象的资源生命周期。 |

### BUG-014：系统采集故障不即时上报

| 字段 | 内容 |
|---|---|
| ID | BUG-014 |
| 类型 | Bug / UX |
| 严重级别 | P1 严重 |
| 置信度 | 高（代码路径）；中（真实系统故障显示需验证） |
| 位置 | [WhisperPipeline.swift:448](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift:448)、455，recordingOutput(_:didFailWithError:)/stream(_:didStopWithError:)；finishStopIfPossible:462；[MeetingStore.swift:301](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:301) 的录音器接线 |
| 问题描述 | 采集错误仅保存为 stopError 并调用 finishStopIfPossible；后者第一句要求 stopRequested。如果错误在正常录音期间发生，直接返回，没有向 Store 发布失败，也没有主动停止并保存已录部分。Store 保持录音状态，计时与装饰柱形仍可继续。 |
| 证据 | `guard stopRequested else { return }` 在错误处理前；MixedRecordingSession 没有对 Store 的错误事件出口。启动成功后，Store 仅依赖用户 stop 的结果发现错误。源码路径确定，未制造真实系统故障。 |
| 影响 | 采集已经中断而用户以为仍录着，直到结束会议才得知失败，无法在发生时采取恢复措施。与第一批 UX-001 假信号表叠加，但本项根因是错误传播缺失。 |
| 复现步骤 | 需验证：用可注入流适配器或隔离实机在录音期间触发采集失败，保持 stopRequested=false。检查 Store 是否即时进入失败/中断状态、保存现有内容与给出恢复动作。本批仅追踪了代码，没有把系统错误发生率当事实。 |
| 建议修复 | 录音器提供明确的 started/stopped/interrupted/failed 事件接口；错误事件无需等待用户 stop。Store 收到后只更新对应 operation，停止剩余采集、保留可恢复文件、展示原因和下一步。避免递归 stop 或重复 resume。 |
| 验证方式 | 正常采集中断、输出失败、启动期间失败、stop 与失败同时发生四类顺序均测。界面即时停止计时/错误信号，错误只报告一次，部分录音可恢复，后续操作不被旧回调污染。 |
| 是否 AI 生成典型问题 | 是：实现了 delegate 方法，却只覆盖“用户主动停止”的错误出口。 |

### BUG-015：分块归属丢弃边界句子的后半段

| 字段 | 内容 |
|---|---|
| ID | BUG-015 |
| 类型 | Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高（构造输出处理结果）；中（真实引擎出现频率未测） |
| 位置 | [MeetingStore.swift:1788](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:1788)，chunkWindow；1800，ownedSegments；1193、1759 的调用 |
| 问题描述 | 起点早于当前 coreStart 的段一律归前块；但前块只多读 2 秒，未必包含该段的完整结尾。下一块得到同一长句更完整的结果后仍丢掉整个段，尾部没有任何块保留。原有“每段恰好归一块”测试使用同一份人工时间线，未覆盖两次转写的文本与分段不同。 |
| 证据 | 第一块实际读到 602 秒，输出 599–602“下周一”；第二块从 598 秒读，输出 599–606“下周一交付最终报价单。”。实际 ownedSegments 拼合只留下“下周一”。这是合法窗口内的构造转写输出，没有宣称来自实测语音。 |
| 影响 | 恰好跨 10 分钟切点的长句，可能丢掉完整待办、数字或条件；全文仍顺畅，错误不显眼。原始音频保留，能够重新转写核查。 |
| 复现步骤 | 1. 建立 1200 秒音频的前两块窗口。2. 给前块注入 599–602 截断段，后块注入 599–606 完整段。3. 分别调用 ownedSegments 再拼接。4. 确认只剩截断段。探针 testChunkOwnershipDiscardsTheMoreCompleteBoundarySentence。 |
| 建议修复 | 边界采用时间覆盖与文本/token 重叠对齐，合并截断段与更完整的新段，保证前块读取终点之后的内容不丢；维护原始块输出以便核对。不能仅放宽起点过滤后重复全文，也不能只增加固定重叠时长而不处理任意长句。 |
| 验证方式 | 在切点前 1–2 秒开始、切点后 3–10 秒结束的句子，分别模拟相同/不同分段与文本截断。全部独有内容保留且不重复，时间顺序正确；再用真实中文音频验证该类边界。 |
| 是否 AI 生成典型问题 | 是：测试钉住现有公式，却未验证“完整内容不丢”的真实契约。 |

## 修复建议与回归顺序

先修第一批 BUG-001 的旧结果保护，再并行按职责排下列工作；这里的“并行”是开发排期建议，本次审查没有委派其他 agent。

| 顺序 | 工作组 | 最小可执行修复 | 验收重点 |
|---|---|---|---|
| 1 | 文本忠实性：BUG-008/009 | 禁止跨 speaker 并句，撤掉会误删相反意见的模糊串音去重 | 肯定/否定、金额、负责人反例都保留；独立发言来源不变 |
| 2 | 生命周期：BUG-011/013/014 | operation ID 校验、活动录音先停止后删除、错误事件即时上报 | 旧任务不能动新任务；用户界面与实际采集一致 |
| 3 | 取消退出：BUG-012 | 指定进程的有界终止与一次性 continuation 收尾 | 忽略 TERM 时也能在约定时限内回到可操作状态 |
| 4 | 时间与完整性：BUG-006/007 | 保留共同时间原点/缺口，轨道完整性契约与降级提示 | 两路同一时刻对齐；截断轨道不冒充完整 |
| 5 | 检查点：BUG-010 | 按来源持久化，保留全部已完成片段 | 任一块失败后内容可见，按来源续跑 |
| 6 | 分块边界：BUG-015 | 边界段文本与时间对齐合并 | 跨切点语句尾部不丢、全文不重复 |

文本边界的最小保护示例（需同时在复读折叠处保护，并补回归，不能只改这一行）：

```swift
let sameSpeaker = current.speaker == segment.speaker
let nearby = segment.start >= current.start && segment.start - current.end <= allowedMergeGap
if sameSpeaker && nearby && !alreadyEnded && candidate.count <= limit {
    // 原有同一来源并句逻辑
} else {
    result.append(current)
    buffer = segment
}
```

异步收尾必须使用唯一操作 token，单纯比较 sessionID 不够，因为同一场会议也可能快速取消后重新处理：

```swift
// 在创建每次工作时建立 UUID，所有成功、失败、取消与 finally 分支都携带它。
guard activeOperationID == operationID else {
    // 只清理本次操作自己的资源，不更新新操作的 UI/任务句柄。
    return
}
```

以上是实现方向示例，并未作为业务补丁应用；信号/进程强制结束、时间映射和检查点涉及更多资源契约，不能用示例替代完整修复。

## 回归验收清单

- [ ] 两路首包延迟、时间缺口、重复/乱序包不改变真实时间轴，回放定位正确。
- [ ] 某路格式/写盘失败时保住混合原件和可用内容，给出真实的降级与完整性状态。
- [ ] 不同 speaker 的提问/承诺、独立重复确认、相反意见均保留原归属和独有文本。
- [ ] 金额、否定、日期与负责人变化不能被去重删除。
- [ ] 双路每个检查点的失败/重启都保留全部已完成块及其来源。
- [ ] 删除/取消 A 后开始 B，A 的任何晚到回调不影响 B。
- [ ] 停止操作在可验收的时间上限内完成，进程/子进程/continuation 都收尾。
- [ ] 删除活动录音前，实际采集停止、句柄关闭、UI 停止状态正确。
- [ ] 系统错误即时通知界面，已录部分可恢复，不持续假装录音。
- [ ] 每个分块切点附近长句保留完整文本，真实音频回放核对一致。
- [ ] 第一批旧结果保护与输入归一化回归同时保持通过。

## 下一批建议

下一批进入真实界面、首次使用、错误恢复、键盘与 VoiceOver 可访问性审查，并检查设置/模型授权、三页内容一致性、导出、编辑和回放的实际交互。之后再分别进行云端接口与密钥/文件/分发安全、性能及维护性，最终汇总成修复排期报告。

本批现有材料足够，不需要填写项目描述。按用户约定分批，交付后确认是否进入下一批。
