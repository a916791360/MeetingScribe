# MeetingScribe 0.11.9 修复与实际验收

## 结论

累计52项审查发现（P0 1 / P1 32 / P2 19），其余确定缺陷已实施修复；ARCH-001维持渐进改善，完整外部及特殊设备矩阵仍待验证。最新版本0.11.9/build29已安装、正常启动并留在空闲状态。原3场会议24文件（291314048字节）及全部JSON字段与升级前一致。

本轮实际录音发现此前漏查的P1隐私问题：备用MOV含屏幕视频流，已改为纯音频WAV并实际双轨验证。正常退出保护、后台终态落盘、5万句阅读性能、截止日期和权限警告也已修复。不能把本机回归成功称为“全部场景验收完成”。

| 优先级 | ID | 结果 |
|---|---|---|
| P1 | SEC-007 | 移除非预期视频落盘，纯音频备用source及原CAF保留；生产App最终27秒双轨实测通过 |
| P1 | BUG-030 | 正常退出覆盖准备、录音、处理；等待durable收尾再释放占用；原生与故障回归通过 |
| P2 | PERF-002（既有） | >1000句每500句分段，当前句跨页定位；5万句45秒采样0条>250ms hang；1501句完整导出通过 |
| P2 | ARCH-001（既有） | 剩余manifest草稿/终态/retry移入actor事务；Store业务编排仍集中，继续渐进拆分 |
| P2 | BUG-031 | 保留完整截止星期/时段；有效反例先失败，修复与原生导出通过 |
| P2 | UX-009 | 导入清除旧录音权限警告；未授权隔离App导入实测通过 |

## 新增P1：优先修复并已验收

### SEC-007：备用录音包含非预期屏幕视频

| 字段 | 内容 |
|---|---|
| ID | SEC-007 |
| 类型 | 安全 / 隐私 |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | 修复前WhisperPipeline.swift / MixedRecordingSession的SCRecordingOutput；当前WhisperPipeline.swift:390、AudioOnlyRecordingAssembler.swift:6、SessionStorage.swift:276 |
| 问题描述 | “会议录音”的备用source.mov同时保存屏幕视频，可能把其他窗口内容带入原件。 |
| 证据 | native-capture-before-audio-only.json：实际54秒备用MOV具有AAC音频和H264视频流；代码使用display过滤器与SCRecordingOutput。没有查看视频内容或证明凭据已泄漏。 |
| 影响 | 分享或留存原录音时可能包含未预期屏幕内容，超出音频转写目的。 |
| 复现步骤 | 1. 修复前版本在已有系统/麦克风权限下采集。2. 正常结束。3. ffprobe检查source.mov，存在video流。仅在受控合成画面下复现。 |
| 建议修复 | 已移除SCRecordingOutput，仅接audio/microphone；设备停止后排空样本队列并关闭CAF，以16384帧块后台混音为16k单声道source.wav，成功关闭后原子替换；取消owner仍等待独立收尾。保留原CAF和旧MOV，不擅自清除历史数据。 |
| 验证方式 | AudioOnlyRecordingAssemblerTests验证时间补零、不同尾长、48k归一化、失败不改旧source、取消仍保存；最终生产录音ffprobe确认所有媒体只有audio，CAF存在且无MOV；旧MOV分享前检查并提取音频。 |
| 是否 AI 生成典型问题 | 不确定；缺少输出媒体范围验证的模式符合“表面可用”风险，不能证明作者身份。 |

### BUG-030：正常退出不保护录音和处理

| 字段 | 内容 |
|---|---|
| ID | BUG-030 |
| 类型 | Bug / 数据完整性 |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | MeetingApplicationDelegate.swift:7 / applicationShouldTerminate |
| 问题描述 | 旧退出守卫只保护编辑保存/删除，录音准备、活动录音及转写整理仍可正常退出，打断设备与终态写盘。 |
| 证据 | 修复前delegate未检查isRecording/isPreparingRecording/isProcessing；BackgroundLifecycleTests.testActiveCaptureAndProcessingRefuseNormalQuit验证这些分支；隔离准备/处理及生产活动录音⌘Q实测被阻止。 |
| 影响 | 用户按⌘Q可能留下不完整录音或未完成状态，核心流程中断；强制结束及系统断电仍不受正常退出守卫保证。 |
| 复现步骤 | 1. 旧版开始录音或处理。2. 按⌘Q。3. 应用退出；使用合成夹具验证，避免损害真实会议。 |
| 建议修复 | 已增加准备/采集/处理terminateCancel，提示停止录音或取消处理并等待保存；剩余草稿/status/retry/失败终态迁入SessionRepository，终态提交后才释放占用，避免取消过早允许退出。 |
| 验证方式 | 5项BackgroundLifecycleTests覆盖草稿提交前取消、导入取消、retry保全部manifest、恢复占用/保重命名、退出守卫；正常空闲⌘Q可退出。 |
| 是否 AI 生成典型问题 | 不确定 |

## 新增P2：功能与体验

### BUG-031：本地待办截止日期被截短

| 字段 | 内容 |
|---|---|
| ID | BUG-031 |
| 类型 | Bug |
| 严重级别 | P2 一般 |
| 置信度 | 高 |
| 位置 | MeetingStore.swift:2391 / MeetingAnalysisBuilder.dueText |
| 问题描述 | 逐字稿明确“下周三”，本地整理仅保存“下周”；具体日期后的时段也被丢失。 |
| 证据 | export-before-deadline.md与deadline-repro.log：有效3测试7断言失败；当前export-final.md待办保留“下周三”。 |
| 影响 | 待办时间精度降低，用户可能错过约定时间。 |
| 复现步骤 | 1. 输入达到素材门禁的合成逐字稿，含“约定交付日期是下周三”。2. 使用本地保守整理。3. 检查dueText及Markdown。 |
| 建议修复 | 已先匹配完整年月日/具体星期，再匹配相对日期，并保留上午/下午/几点/半等时段；保留原文相对表述，不凭空转换实际日期。 |
| 验证方式 | LocalActionDeadlineTests三项验证具体星期/时间、年月日/相对日时段、无截止日期不编造；最终原生UI和Markdown显示下周三。 |
| 是否 AI 生成典型问题 | 不确定 |

### UX-009：导入后残留录音权限警告

| 字段 | 内容 |
|---|---|
| ID | UX-009 |
| 类型 | UX / Bug |
| 严重级别 | P2 一般 |
| 置信度 | 高 |
| 位置 | MeetingStore.swift / importAudio |
| 问题描述 | 系统采集未授权时尝试录音留下captureBlockedNotice，转而导入音频后仍显示该录音警告。 |
| 证据 | 独立Device App权限preflight及后续原生导入路径；synthetic-pipeline.json记录import_clears_previous_capture_permission_notice=true；importAudio现清空旧notice。 |
| 影响 | 导入用户被无关警告干扰，误以为已导入会议处理失败。 |
| 复现步骤 | 1. 无屏幕采集权限尝试录音。2. 改为导入已有音频。3. 检查导入结果和警告。 |
| 建议修复 | 已在开始导入时清除上次录音权限提示，导入错误继续用自己的失败状态显示。 |
| 验证方式 | 独立未授权App导入短/长TTS成功，录音权限警告消失；不需要修改系统权限。 |
| 是否 AI 生成典型问题 | 不确定 |

## 本轮修复实施

SessionRepository.createDraft在提交前响应取消，提交后返回已写draft供caller负责收尾，避免孤立recording记录。recover不因owner取消跳过终态写盘，只改最新manifest的状态字段，不覆盖并发名称与原文。retry初始化提交前取消/失败保持旧manifest和检查点；设备停止优先于磁盘读写。5万段后台调度基准见persistence-benchmark.json：最大MainActor间隔同步619.7ms、后台30.9ms；总事务耗时并未同等改善，不能称整App加速。

长原文分页沿用生产store中的编辑草稿、全量导出与播放定位。<=1000句保持单页，>1000每页500句。跨页定位先确定包含句子的页，再滚动；保存期间禁止导航，显示占用与失败恢复指引。

AudioOnlyRecordingAssembler对有效轨道分块混合，失败保旧source；原CAF保留，已为WAV的source直接作为input，避免多复制一次。捕获写盘故障立即回传MainActor，重复故障仅通知一次。旧MOV保持读取兼容，升级未转写或删除历史原件；分享旧MOV前应检查是否含video并提取纯音频。

## 验证与证据

| 验证 | 结果 | 证据 |
|---|---|---|
| Swift全量warnings-as-errors | 371项，1项真实云端跳过，0失败 | swift-final.log |
| Python全量 | 45项通过 | python-final.log |
| 合成质量门禁 | 7case符合预期 | quality-final.log |
| 最终内置真实引擎 | GPU/CPU加载退出0，JSON可解析，599秒offset为绝对时间 | runtime-smoke-final.log |
| 最终发行ZIP | 构建、来源/许可/RPATH、strict签名、解压后审计通过 | package-final.log、zip-final.log、extracted-audit-final.log |
| 真实短录音 | source及两路CAF/WAV全部audio、ready、无captureWarning | native-capture-final.json |
| 真实TTS转写/整理/播放/导出 | 8段、2决策/1待办，截止下周三；本样本CER5.05% | synthetic-pipeline.json、export-final.md |
| 5万句原生测量 | 修复前4条hang，后0条>250ms；采样后单点RSS降低，非峰值 | profile-before.json、profile-after.json |
| 分页编辑/播放/完整导出 | 75.5秒定位第756句，草稿跨末页保留，键盘保存与1501句导出通过 | pagination-export.json |
| 安装/数据 | 原24文件SHA及完整JSON一致；App最终重启成功 | install-final.json |

详细原生步骤与测量边界见[ui-observations.md](ui-observations.md)。原生结果来自生产App及生产源码构建的两种独立审查App，明确区分注入延迟和真实设备路径。

首次测试失败日志保留：tests-first/second/third主要为旧同步夹具、测试参数及启动迁移快照时点失配；deadline-before是素材不足，不能作为日期bug证据。deadline-repro才是修复前有效产品反例（3项7断言失败）。audio-only-compile-first是首轮编译成功日志。原始日志保持原样。

## 排期与回归验收

1天内修复项本轮已完成：纯音频备用、退出守卫、后台终态、截止精度、权限文案、分页。回归要求：再次运行Swift/Python/质量门禁；受控录音ffprobe无video且原CAF存在；取消草稿不留孤立会话；retry取消不改旧manifest；跨页编辑和全量导出不漏句。

1–2周优先补验证而非重写：首次授权/拒麦克风/撤销权限/拔插耳机、3小时录音与多声源偏移；VoiceOver朗读与焦点；真实HTTPS云端弱网与认证。第二台Apple Silicon/macOS15用户确认暂无设备，因此保持待验证。无专用云端接口，不使用用户真实Key或会议做测试。

长期保持渐进拆分Store业务编排、基于真人授权样本的质量评测、依赖advisory跟踪。正式公开发行需要Developer ID与Apple公证，体检确认本机缺证书/凭据；不通过自签替代公证。

- [x] 当前371/45/7回归通过。
- [x] 真实默认双轨采集、正常停止、转写、备用纯音频、原CAF保留。
- [x] 最终安装/重启/真实数据完整性。
- [x] 1501句播放跨页、草稿保留、⌘↩保存、完整原生导出。
- [x] 短/长合成语音真实引擎与本地整理/导出。
- [ ] macOS15另机、完整权限/设备与长时矩阵。
- [ ] VoiceOver真实朗读。
- [ ] 真实专用HTTPS云端弱网/认证。
- [ ] Developer ID和Apple公证。

## 安装、备份与回滚

最终安装：/Applications/MeetingScribe.app，0.11.9/build29，本机PM Studio Signing自签。最新私有备份：`/Users/qingmeng/Documents/Codex/MeetingScribe-backups/20261006-163850`，含完整原24文件与0.11.8 App；此前0.11.7备份在20261006-162039。实际测试录音已从用户会议目录移到对应私有备份；原3场数据完整不变。备份不在源码或交付中。

回滚：先在App空闲时正常⌘Q，保留当前App至另一个本机目录；将备份MeetingScribe-previous.app复制到同卷临时位置验签，完成后替换/Applications/MeetingScribe.app。当前真实会议数据未改，不需要恢复数据；若以后用户新增会议，不要用旧备份覆盖新会议目录。

GitHub基线固定bd80e302b88622bb435eb73b47b34b847fb3f86f，分支codex/audit-hardening；不推送、不公开发布。完整源码ZIP、基线binary patch、App ZIP与SHA清单另建不可变交付目录，路径记录在ignored .review-dist/acceptance-delivery-location.txt。原始音视频、私有备份、原始trace不包含在交付中。
