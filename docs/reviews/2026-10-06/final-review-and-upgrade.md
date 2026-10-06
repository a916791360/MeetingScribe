# MeetingScribe 完整审查与0.11.6升级报告

日期：2026-10-06。审查与代码修改以GitHub提交 `bd80e302b88622bb435eb73b47b34b847fb3f86f`（0.11.1/build21）为基线，在独立分支 `codex/audit-hardening` 实施。原项目工作目录保留；本地App已更新到0.11.6并完成安装后数据核对；本轮启动因Mac锁屏待验，真实会议仅用于无内容输出的数据完整性核对，故障测试使用合成夹具，未使用真实凭据或云端接口。

## 执行摘要

项目是Swift 6/SwiftUI的macOS 15+、Apple Silicon原生会议工具：ScreenCaptureKit录系统/麦克风，AVFoundation落盘与播放，afconvert归一化，whisper.cpp本机转写，可选本地规则/Ollama/OpenAI兼容接口整理，JSON会话与Markdown导出。单SwiftPM应用模块，无Web后端或数据库服务。

完成了架构、功能、UX/可访问性、安全、性能、可维护性、AI典型错误七个维度，五批42项与后续6项，共48项：**P0 1 / P1 30 / P2 17**，另1项原生读屏观察仍需VoiceOver验证。数量不是线上事故数：例如本地文件篡改、服务回显、异常CLI都有触发前提。没有使用人为分数评估健康度。

最大风险原为重试覆盖旧校正/纪要，以及时间轴、说话人、否定意见与双路检查点的静默损坏。本轮已用保留旧结果、任务归属检查、保守后处理和故障回归降低这些风险。网络目的地、错误信息、文件边界和发行产物也已加固。代码已升到**0.11.6/build26**；后续完成独立单路/双路恢复检查点、后台原子保存、自定义名称保留和官方运行时来源锁定，前轮已完成历史诊断清理与后台首次加载/导入，0.11.6补齐取消收尾门禁、导入重命名保护与后台旧结果发布版本控制，并完成合成保存调度和1000段原生Instruments测量。仍有架构渐进改进与真实设备验收，不能把本地全绿当作公开发行完成。

## Top 10 高优先级问题

下表是修复/验收优先顺序，P0单独置首；详细影响和触发前提见后面的逐项12字段表。

| 顺序 | ID / 级别 | 问题 | 本轮结果与验收 |
|---|---|---|---|
| 1 | BUG-001 / P0 | 重试销毁已有结果 | 已修复 / 故障回归；testFailedRetryPreservesSavedManualEditsAndMinutes |
| 2 | SEC-002 / P1 | 云端正文跟随跨来源重定向 | 已修复 / 真实loopback；testCrossOrigin307DoesNotForwardMeetingOrCredentials：目标零请求；HTTPS/跨主机矩阵待补 |
| 3 | SEC-003 / P1 | 会话清单能改变数据根之外的操作目标 | 已修复 / 故障回归；manifest ../不能删根外；symlink不能写根外。未宣称抵御同机恶意进程的TOCTOU竞态 |
| 4 | SEC-004 / P1 | 原始服务端错误污染会议文件与导出 | 新写入与历史诊断已修复 / 合成迁移回归；旧导出和其他备份不自动清除，真实库在运行新版时清理 |
| 5 | BUG-006 / P1 | 写盘丢失音频时间位置 | 合成验证 / 需实机；testSampleTimestampGapIsPreserved、testSharedEpochPreservesFirstPacketOffsetsAndActualLevels；MOV首包/设备偏移需实测 |
| 6 | BUG-008 / P1 | 后处理无视说话人边界 | 已修复 / 回归；testCleaningPreservesDifferentSpeakers、testIndependentRepeatsBySameSpeakerArePreserved |
| 7 | BUG-009 / P1 | 相反意见被误判为串音 | 已修复 / 回归；testCrosstalkPreservesOppositeDecisions及合并测试；近似串音可能多保留一句，是避免误删的取舍 |
| 8 | BUG-010 / P1 | 双路检查点覆盖完整的一路 | 已修复 / 故障回归；testSecondTrackFailurePreservesFirstTrackCheckpoint；0.11.5再验证双路/单路中断只重跑未完成分块、源/模型变化失效 |
| 9 | BUG-011 / P1 | 旧任务收尾破坏新任务状态 | 已修复 / 竞态回归；testDeletionWaitsForOldTaskBeforeStartingAnother；0.11.6再验取消整理保持占用、删除等待实际收尾 |
| 10 | BUG-012 / P1 | 超时和取消没有进程退出上限 | 已修复 / 故障回归；testCancellationFinishesEvenIfCLIRejectsSIGTERM；真实长超时未等待 |

## 完整问题列表与修复状态

“已修复”指当前实现与注明的验证范围；“需实机”并不表示已完成真实采集验收。ARCH-001为部分改善；SEC-004现含历史清理，真实库在启动新版时处理，旧导出与其他备份不自动清除。最新修复和验收见[0.11.6报告](lifecycle/review-and-upgrade.md)，上轮见[0.11.5报告](continuation/review-and-upgrade.md)，前轮原生验收与安装见[0.11.4报告](ui-final-review-and-install.md)，历史闭环见[0.11.3追加报告](closure-review-and-upgrade.md)。原始第一至四批表中的行号属于固定基线，详情中已转换为GitHub基线链接；当前修复位置另列本地链接。

| ID | 原严重级别 | 类型 | 问题 | 当前状态 | 当前修复位置 |
|---|---|---|---|---|---|
| BUG-001 | P0 | Bug | 重试销毁已有结果 | 已修复 / 故障回归 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| BUG-002 | P1 | Bug | 重试漏掉输入归一化 | 已修复 / 故障回归 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| BUG-003 | P1 | Bug / AI生成代码 | 保存失败却返回成功草稿 | 已修复 / 故障回归 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| BUG-004 | P1 | Bug / UX | 读取错误与空列表混为一谈 | 已修复 / 故障回归 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| BUG-005 | P1 | Bug / 架构 | 准备开录没有占用任务状态 | 代码已修复 / 需实机 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| BUG-006 | P1 | Bug | 写盘丢失音频时间位置 | 合成验证 / 需实机 | [AudioTrackRecorder.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/AudioTrackRecorder.swift) |
| BUG-007 | P1 | Bug / UX | 失败的半条音轨仍参与完整转写 | 合成验证 / 需实机 | [AudioTrackRecorder.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/AudioTrackRecorder.swift) |
| BUG-008 | P1 | Bug | 后处理无视说话人边界 | 已修复 / 回归 | [TranscriptCleaner.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/TranscriptCleaner.swift) |
| BUG-009 | P1 | Bug / AI生成代码 | 相反意见被误判为串音 | 已修复 / 回归 | [TranscriptMerger.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/TranscriptMerger.swift) |
| BUG-010 | P1 | Bug | 双路检查点覆盖完整的一路 | 已修复 / 故障回归 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| BUG-011 | P1 | Bug / 架构 | 旧任务收尾破坏新任务状态 | 已修复 / 竞态回归 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| BUG-012 | P1 | Bug | 超时和取消没有进程退出上限 | 已修复 / 故障回归 | [WhisperPipeline.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift) |
| BUG-013 | P1 | Bug / 安全（录音生命周期） | 删除活动录音未停止采集 | 代码已修复 / 需实机 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| BUG-014 | P1 | Bug / UX | 系统采集故障不即时上报 | 代码已修复 / 需实机 | [WhisperPipeline.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift) |
| BUG-015 | P1 | Bug | 分块归属丢弃边界句子的后半段 | 已修复 / 回归 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| BUG-016 | P1 | Bug / UX | 人工校正后旧整理结果没有过期状态 | 已修复 / UI与回归 | [MeetingModels.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingModels.swift) |
| BUG-017 | P1 | Bug / UX | 全文型历史记录在原文页被隐藏 | 已修复 / UI与回归 | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| BUG-020 | P1 | Bug / AI生成代码 | 流式响应没有结束证据也宣称完成 | 已修复 / 协议回归 | [SummaryEngine.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift) |
| BUG-022 | P1 | Bug | 时间锚解析与显示可能整数溢出崩溃 | 已修复 / 边界回归 | [MeetingModels.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingModels.swift) |
| BUG-023 | P1 | Bug / 数据完整性 | 导入input.wav会与标准化输出重名并替换本机副本 | 已修复 / 文件回归 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| BUG-024 | P1 | Bug / 数据安全 | 安装前强制结束App，且未完成复制就移走旧版 | 已修复 / 隔离故障回归 | [Scripts/install_app.sh](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/install_app.sh) |
| BUG-025 | P1 | Bug / AI生成代码 | 静音门禁覆盖不一致与轻声信号误过滤 | 已修复 / 回归；真实噪声待验 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| BUG-026 | P1 | Bug / 录音生命周期 | 磁盘读取失败绕过停止采集 | 已修复 / 注入故障回归；真实设备待验 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| BUG-027 | P1 | Bug / 网络兼容 | 合法同来源跳转丢失认证头 | 已修复 / loopback允许与拒绝矩阵 | [SummaryEngine.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift) |
| SEC-002 | P1 | 安全 | 云端正文跟随跨来源重定向 | 已修复 / 真实loopback | [SummaryEngine.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift) |
| SEC-003 | P1 | 安全 / Bug | 会话清单能改变数据根之外的操作目标 | 已修复 / 故障回归 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| SEC-004 | P1 | 安全 | 原始服务端错误污染会议文件与导出 | 已修复 / 历史迁移故障回归 | [SummaryEngine.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift) |
| SEC-005 | P1 | 安全 / AI生成代码 | 评测配置把地址和凭据分别补齐 | 已修复 / mock回归 | [Scripts/llm_judge.py:148](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/llm_judge.py:148) |
| UX-002 | P1 | UX / Bug | 待办负责人保存了却没显示 | 已修复 / UI | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| UX-004 | P1 | UX | 缺麦克风权限的后果说明不完整 | 代码已修复 / 需实机 | [MeetingModels.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingModels.swift) |
| UX-007 | P1 | UX / Bug | 准备期误称已采集且提前计时 | 已修复 / 原生合成UI与回归 | WorkbenchView.swift、MeetingStore.swift |
| ARCH-001 | P2 | 架构 / 可维护性（附性能风险） | 编排与副作用集中，隔离不足 | 部分改善 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| BUG-018 | P2 | Bug | 字符长度限制不保证合法文件名字节数 | 已修复 / 写盘回归 | [MeetingExport.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingExport.swift) |
| BUG-028 | P2 | Bug / UX | 重新处理覆盖自定义会议名 | 已修复 / 恢复与导入回归 | MeetingStore.swift、MeetingModels.swift、SessionStorage.swift；详情见0.11.5及0.11.6追加报告 |
| BUG-029 | P2 | Bug / UX | 晚到后台结果覆盖新名称UI | 已修复 / 发布时序回归 | MeetingStore.swift、SessionStorage.swift；详情见0.11.6追加报告 |
| BUG-019 | P2 | Bug / 性能 | 播放器计时器没有覆盖离开与失败生命周期 | 已修复 / 生命周期回归 | [AudioPlayback.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/AudioPlayback.swift) |
| BUG-021 | P2 | Bug / 性能 | 网关正常返回普通 JSON 却被重复调用 | 已修复 / 请求计数 | [SummaryEngine.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift) |
| DOC-001 | P2 | UX / 可维护性 | README宣称不联云，与可选云端整理不一致 | 已修复 / 文档核对 | [README.md](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/README.md) |
| PERF-001 | P2 | 性能 | 每次读取单条会议都会枚举解码整个数据根 | 已修复 / 合成性能 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| PERF-002 | P2 | 性能 / 可访问性 | 长逐字稿一次创建全部行 | 代码、AX与本机合成采样改善 / VoiceOver和其他规模待验 | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| PERF-003 | P2 | 性能 / 可维护性 | 子进程日志无界写入、结束后整文件读入 | 已修复 / 故障回归 | [WhisperPipeline.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift) |
| SEC-001 | P2 | 安全 / 可维护性 | 审计通过与实际 Mach-O 路径不一致 | 已修复 / 产物验证 | [Scripts/package_app.sh](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/package_app.sh) |
| SEC-006 | P2 | 可维护性 / 许可证风险 | 发行包没有保留内置运行时和模型的第三方许可 | 许可与官方来源锁定 / 产物验证 | [Scripts/package_app.sh](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/package_app.sh) |
| UX-001 | P2 | UX / AI生成代码 | 装饰动画被放在真实音源状态位置 | 合成验证 / 需实机 | [AudioTrackRecorder.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/AudioTrackRecorder.swift) |
| UX-003 | P2 | UX / Bug | 切页静默丢弃未保存草稿 | 已修复 / UI | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| UX-005 | P2 | UX / 可访问性 | 编辑输入框没有可访问性名称 | 已修复 / AX | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| UX-006 | P2 | UX / 可访问性 | 工具栏导入和设置被读成开始录音 | 已修复 / AX | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| UX-008 | P2 | UX / Bug | 取消准备被当故障 | 已修复 / 原生合成UI与故障回归 | MeetingStore.swift、SafeDiagnostics.swift |

## 项目结构、风险与适用范围

| 模块 | 责任 | 审查与修复重点 |
|---|---|---|
| MeetingStore / 新SessionStorage | 编排状态、JSON持久化、导入/恢复 | 保留旧结果、任务归属、失败可见、文件根约束、索引；Store仍需分层 |
| WhisperPipeline / AudioTrackRecorder | 录音、转码、CLI、分块、双路 | PTS、采集故障、失败轨道、静音、跨界句、进程退出与资源边界 |
| TranscriptCleaner / Merger / Material | 清洗、去串音、整理门禁 | 说话人边界、否定和数字差异、保守保留 |
| SummaryEngine / Discovery / Keychain | 云端/Ollama与密钥 | 同来源redirect、错误体分类、流式结束、响应上限、凭据来源 |
| WorkbenchView / AudioPlayback / Export | 三页阅读、编辑、回放、交付 | owner、草稿、stale、历史全文、AX、惰性列表、Timer和文件名 |
| Scripts / Packaging / CI / Tests | 安装、签名、打包、评测 | RPATH、每个Mach-O签名、许可、安装回滚、离线门禁 |

未发现需要整体重写的证据。Swift单模块没有npm式依赖或循环包导入；大型Store/View和同步I/O是维护问题，按模块渐进拆分更合理。JSON布局无SQL/N+1数据库查询，但此前有“每次查单条读整个目录”的类似读取放大，已用索引修复。新的optional字段保持旧JSON解码兼容，损坏/越界记录不会静默消失。

OWASP检查按原生桌面边界应用：认证/会话是第三方模型凭据与系统权限；授权和路径是本机文件边界；不具备本站用户登录、Cookie业务会话或Web数据库，SQL注入、浏览器CSRF、网站CORS/CSP不应机械计为缺陷。未新增本机权限、未读真实Key、未操作系统授权。固定官方来源与模型SHA已验证，OSV提交及公开advisory查询已完成并未返回匹配记录；这些结果不能断言whisper.cpp/ggml无漏洞，仍需持续跟踪。

性能以原生I/O、列表构建、进程资源与请求次数衡量，Web LCP/CLS不适用于该界面。100会议×300段、查询最后一条20次：**1.197790秒→0.013592秒（约88.1倍）**，不是整App或首屏快88倍。Lazy列表已用1000段AX和首尾滚动验证；0.11.6补20.7秒Time Profiler采样，potential-hangs为0条（250ms阈值），AX访问参与测量。未测FPS/峰值内存。5万段连续3次事务的最大MainActor调度间隔同步617ms、后台7.6ms；总平均事务耗时相近，不能等同单次耗时或整App性能。

AI专项确认的典型模式包括吞掉落盘错误、貌似合理却跨speaker清洗、字面相似度误删否定、EOF假完成、配置拼凑凭据、文档承诺漂移与安装只考虑成功路径。此处识别的是代码模式，不证明作者身份。没有凭模型名字或未经调用的网络API就认定“幻觉API”。Swift6 warnings-as-errors、实际系统API编译和350项回归提供运行证据；没有把本地保守整理的空结果误判为伪实现。

## 本轮新增确认缺陷

| ID | 级别 | 类型 | 问题 | 状态 |
|---|---|---|---|---|
| BUG-026 | P1 | Bug / 录音生命周期 | 磁盘读取失败绕过停止采集 | 已修复 / 注入故障回归；真实设备待验 |
| BUG-027 | P1 | Bug / 网络兼容 | 合法同来源跳转丢失认证头 | 已修复 / loopback允许与拒绝矩阵 |

新增问题的12字段详情附在文末；历史诊断清理、后台I/O与录音故障补验见[追加报告](closure-review-and-upgrade.md)。

## 验证结果与证据

本机macOS 26.5.2、Swift 6.3.3、arm64；最低支持macOS15没有在本轮本机运行，CI配置不是本轮CI执行结果。确切环境记录见upgrade-environment.log。

| 验证 | 结果 | 证据 |
|---|---|---|
| Swift全量 | 350项，1项云端E2E跳过，0失败；warnings-as-errors | lifecycle/full-tests-final.log |
| Python指标 | 28项通过 | upgrade-python-quality.log |
| Python凭据 | 5项mock通过 | upgrade-python-credentials.log |
| Python安装与来源 | 5项安装故障、7项来源验证；与指标/凭据共45项通过 | lifecycle/python-tests-final.log |
| 合成质量门禁 | 7个case与预期一致，含已知退化反例 | lifecycle/quality-final.log |
| 合成原生界面 | 0.11.2：草稿、owner、双页过期提示、旧全文、1000段首尾AX、工具栏、浅深色；0.11.4补验准备、取消、再次开始、重开恢复；加载页截图未捕获 | upgrade-ui-observations.md与ui-final/证据 |
| 内置真实引擎 | 官方锁定引擎GPU/CPU加载退出0；JSON可解析，599秒offset保持绝对时间 | lifecycle/runtime-smoke-final.log |
| 发行产物 | 构建、签名、RPATH/依赖/许可、官方来源/打包哈希、复制/解压后验签通过 | lifecycle/package-final.log / zip-final.log / extracted-audit-final.log |
| 合成保存与原生采样 | 1千/1万/5万段调度基准；1000段原生采样20.7秒、无250ms hang记录 | lifecycle/persistence-benchmark.json、ui-observations.md |
| 基线对照 | 原290测试与前四批故障取证 | baseline-swift-test.log / batch-01至04-repro.log |

引擎烟测还检出了静音幻觉：直接调用small模型会把全零音频转成虚构文字。App单路/双路数字静音门禁现已补齐，低于原-40dB阈值的有效信号保留；这是App入口防护，不是模型准确率证明。复杂噪声、轻声真实会议、方言/重叠讲话需要另做VAD与质量评测。

升级中的两个失败均留证并已纠正：日志监控的URL资源大小缓存让首次新测试失败，已改实时属性并通过回归；重定位移除引擎旧签名后仅签外层App使首个引擎烟测退出-9，已显式签每个运行时并重测。进一步全路径检查还发现SwiftPM写入主程序的Xcode工具链RPATH，现已清理；系统/usr/lib/swift保留，注入/tmp绝对RPATH的签名夹具必须被审计拒绝。失败日志为upgrade-tests-log-limit-before-fix.log和upgrade-runtime-smoke-before-sign-fix.log，不属于最终验收结果。

## 快速修复清单：1天内

这些改动已经实施，可按验收清单复查，不需要另开重写项目。

- 数据：抛草稿落盘错误、报告损坏记录、重试保旧结果、导入保留名、极端时间与UTF8文件名保护。
- 内容：跨speaker并句限制、否定/数字保留、双路检查点合并、边界句保留、统一数字静音探针。
- UX：owner显示、跨Tab草稿、原文校正后stale、旧版全文可见、AX名称与真实音源电平。
- 安全/发行：拒绝跨来源redirect、服务错误分类、凭据源绑定、路径校验、RPATH/内层签名/许可审计、安全安装回滚。
- 性能：目录索引、避免每次更新全表排序、惰性列表、Timer释放、异常日志终止、普通JSON单请求复用。

## 短期改进：1–2周

| 顺序 | 工作 | 关联问题 | 执行者 / 验收 |
|---|---|---|---|
| 1 | 实机录音矩阵：首次授权、拒麦克风、系统声+耳机、设备拔插、超时停止、快速开始/停止、处理取消重开 | BUG-005/006/007/013/014、UX-001/004 | QA+全栈；合成双声源标记对齐MOV/双轨，故障即时提示且原件保留 |
| 2 | VoiceOver与键盘全流程，长文时间锚、编辑保存/取消、最小1060×660窗口，动态字体/高对比 | UX-005/006、VERIFY-UX-001、PERF-002 | QA+UX；实际朗读/焦点可达，不能只看AX树 |
| 3 | 历史诊断清理已实施；验收失败提示与旧导出/外部备份边界 | SEC-004 | 安全+全栈；合成旧回显字段在UI/导出/存储均无假Key，业务正文不改 |
| 4 | 首次加载/修补和导入已后台执行；后续按测量迁移小文件保存，扩展磁盘满回归 | ARCH-001 | 架构+全栈；UI可取消、事务顺序可证、旧结果不可被并发写覆盖 |
| 5 | macOS15、Apple Silicon第二台机器、真实云端兼容矩阵与弱网 | 网络/版本验收 | QA；使用专门合成资料与测试凭据，验证redirect/超时/partial/请求次数 |
| 6 | 引擎/模型来源与哈希已锁定，公开漏洞查询已留证；继续维护漏洞评估并完成Developer ID/公证门禁 | SEC-001/006 | 发布+安全；重复构建来源一致，每个二进制签名有效，REQUIRE_NOTARIZATION=1通过 |

时间窗口为排期建议，不是工作量承诺。具体设备/证书与云端测试资源由实际发行条件决定。

## 长期改进与修复路线

先完成上表1–3的数据/采集/交付验收，RecordingSession与SessionLoader已抽出；继续逐步拆TranscriptionCoordinator和SummaryClient；注入存储/进程/网络故障能力，避免把所有副作用继续集中在Store。保持已有文件格式，分阶段迁移，不建议整体重写。

建立可回放的合成端到端录音、恢复和导出场景，与macOS15/最新版本CI一起运行。用Instruments测100/1000/10000段及历史库增长，按测量决定增量载入/分页，避免凭感觉引入数据库。真实语音质量先采专用非敏感样本评测VAD，再决定降噪/分段/模型升级；不得把“更多文字”自动等同于更准确。

0.11.5已从官方whisper.cpp v1.9.4固定提交构建，配置和官方small模型SHA已锁定，来源资源受App签名保护。公开漏洞查询未返回匹配记录，不能证明不存在漏洞；正式发行仍需Developer ID与Apple公证。0.11.4沿用旧引擎的记录保留在前轮报告。

## 回归验收清单

- [x] 旧JSON可解码；损坏目录有提示并保留文件；非法路径/链接不越根操作。
- [x] 失败重试保留旧原文、校正和纪要；M4A归一化；同名input.wav不覆盖原件。
- [x] PTS间隔/共同epoch合成样本；失败半轨拒绝；speaker和否定保留；跨块完整句保留。
- [x] 双路第二路失败保留第一路；旧任务取消/删除不清新任务busy；TERM不退出可KILL。
- [x] 单路数字静音为空，轻信号必须进入CLI；34MiB日志异常有限退出。
- [x] 校正后双页/导出标stale；草稿跨Tab保留；owner和历史全文可见；Timer对象释放。
- [x] 不同端口307目标零请求；无结束SSE标partial；普通JSON一次请求；超大响应拒绝。
- [x] 假服务回显Key不进入新保存/导出；凭据mock按来源绑定；安全安装5种临时故障场景。
- [x] 原生1000段首尾AX、工具栏名称、浅深色截图；最终包签名/路径/许可审计。
- [ ] 真实音源与权限/设备故障、MOV与双轨绝对偏移、长录音GPU与精度。
- [ ] VoiceOver完整朗读/焦点路径、macOS15、真实云端弱网与HTTPS来源矩阵。
- [x] 历史诊断迁移、幂等、清理写入失败安全展示；业务正文不改。
- [x] 官方引擎源码、配置、模型哈希锁定；OSV与公开advisory查询成功并保留结果。
- [ ] 公开发行Developer ID与Apple公证；持续依赖漏洞跟踪。
- [x] 单路/双路各自恢复；源或模型改变不混用检查点；手动名称保留。
- [x] 取消整理等实际收尾才释放占用；删除独立门禁贯穿等待与文件移除；失败保留记录。
- [x] 导入旧草稿不覆盖重命名；晚到后台snapshot不覆盖UI新名；revision溢出/非法mutation拒绝。
- [x] 整理请求点击时固定配置/术语；成功路径不提前生成fallback；合成主线程调度及原生1000段采样。

## 交付与安装状态

源码位于当前独立工作树，分支codex/audit-hardening；本地提交与源码快照可回滚，GitHub未推送、未发布。升级包是本机PM Studio Signing证书签名的审查候选构建，不是Developer ID公证发行包。

最新一轮0.11.6/build26已安装（原生启动因Mac锁屏待验），备份核对见lifecycle/install-final.json，稳定交付路径见.review-dist/lifecycle-delivery-location.txt；全部JSON字段与其他文件逐一核对，具体数量按安装时实际数据。详细问题表、回滚和验收边界见[0.11.6追加报告](lifecycle/review-and-upgrade.md)。

上轮已从0.11.4/build24升级到0.11.5/build25，备份位于/Users/qingmeng/Documents/Codex/MeetingScribe-backups/20261006-135256；启动后全部JSON字段与24个数据文件逐字节一致，详情见continuation/install-final.json。新交付目录路径见工作树.review-dist/continuation-delivery-location.txt，SHA在交付目录内delivery-manifest.json记录。

前轮本机从0.11.1/build21安全升级到0.11.4/build24并启动成功；旧App和约278MiB完整数据备份保留在/Users/qingmeng/Documents/Codex/MeetingScribe-backups/20261006-131922。安装前正常退出，备份逐文件验证，候选复制后验签，再替换。启动后3场会议ID、正文和其他非诊断JSON字段与升级前一致，音频及其他文件逐字节一致，本次清单也未发生重写。安装摘要见ui-final-install.json；未以真实会议或云端做故障测试。

0.11.4升级包、源码快照和完整补丁及SHA在新交付目录delivery-manifest.json记录，路径见.review-dist/ui-final-delivery-location.txt。0.11.3旧交付目录保持不可变。备份含私有会议，仅留本机，不在源码包或证据包中；备份可能保留旧敏感诊断。具体回滚方法和未完成的设备/VoiceOver验收见[0.11.4报告](ui-final-review-and-install.md)。

## 逐项证据、修复与验收详情

前四批的问题字段保留基线事实；“建议修复”是原建议，“本轮实施”说明本次实际改动，两者不混淆。位置链接分别指向固定GitHub基线与当前源码。

### BUG-001：重试销毁已有结果

| 字段 | 内容 |
|---|---|
| ID | BUG-001 |
| 类型 | Bug |
| 严重级别 | P0 阻断：条件性数据丢失 |
| 置信度 | 高 |
| 位置 | [MeetingStore.swift:1003](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1003)，`retryProcessing`；关键清空在 1014–1016，写盘在 1028；失败页入口 `WorkbenchView.swift:587`、2577 |
| 问题描述 | 对已有内容的失败会议重新处理时，先把旧逐字稿、段数组、纪要全部清空并保存，随后才运行转写。转写失败后只有空结果，人工校正无法从原音频恢复；会话级 transcriptEditedAt 还会保留，形成旧校正标记与空正文的不一致。 |
| 证据 | `resetSession.transcriptText = ""`；`resetSession.transcriptSegments = []`；`resetSession.analysis = .empty`；`try storage.save(resetSession)` 在异步工作开始前执行。探针保存人工校正段与纪要，调用 retry 后立即读盘，结果均为空；令 CLI 失败后再次读盘仍为空。 |
| 影响 | 丢失已确认的人工文本与既有纪要。原始录音尚在，但不能还原人工修订；无历史快照或自动回滚。 |
| 复现步骤 | 1. 在临时目录保存一条 failed 会议，包含逐字稿、人工编辑标记、纪要与有效 WAV。2. 将测试 CLI 指向 `/usr/bin/false`。3. 调用 retryProcessing。4. 在任务开始前与失败后分别读 session.json，确认旧内容均已消失。对应探针 `testRetryErasesSavedManualEditsBeforeAnyTranscriptionRuns`。 |
| 建议修复 | 旧结果保持可读，重试结果写到独立 attempt 临时目录与候选会话；任务成功后一次原子替换“当前结果”。失败/取消保留旧版本。若用户选择丢弃人工修订，应提供独立、明确的操作与确认，并先保存可恢复版本。 |
| 验证方式 | 对失败记录分别注入 CLI 退出、模型丢失、转换失败、取消和写盘失败；旧逐字稿、人工标记、纪要逐字保持。成功后新版本一次提交，旧版本可恢复；界面不能误显示旧结果为本次新结果。 |
| 是否 AI 生成典型问题 | 是：先清状态再执行，没有失败回滚；不能仅凭代码模式证明作者使用了 AI。 |
| 本轮实施 | 重试保留旧正文、人工校正和纪要；成功后才替换，保留标记跨崩溃生效 |
| 当前修复位置 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| 当前状态与验收 | 已修复 / 故障回归；testFailedRetryPreservesSavedManualEditsAndMinutes |

### BUG-002：重试漏掉输入归一化

| 字段 | 内容 |
|---|---|
| ID | BUG-002 |
| 类型 | Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [MeetingStore.swift:1005](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1005)、1042，`retryProcessing`；输入选择 `processingInputURL:1534`；正常导入在 416 转换，启动恢复在 1439 按格式转换 |
| 问题描述 | failed 会议没有可用 input.wav 时，会选到原始 source.m4a 或 source.mov；retry 直接 process，没有正常导入/恢复中的转换步骤。转写无法通过。 |
| 证据 | `inputURL: inputURL` 被直接传给 process。探针使用系统工具生成合法 M4A，调用实际 retry 和已安装 whisper 引擎，得到 failed、inputAudioFileName 为 source.m4a、没有 input.wav，报“找不到 whisper 的 JSON 输出。”；同一 M4A 经 AudioTranscoder 转成 WAV 后，同引擎成功生成 JSON。 |
| 影响 | 转换阶段失败、原始录音因退出而中断、或中间 WAV 丢失后的恢复按钮不能完成核心任务。MOV 路径同样漏转换，但本批仅实测 M4A；其他格式后果需逐项验证。 |
| 复现步骤 | 1. 临时 failed 会议仅保留有效 source.m4a，没有 input.wav。2. 指定安装包里的 CLI 与模型。3. 点对应重新处理或调用 retryProcessing。4. 确认失败。5. 将同音频转 WAV，再调用同引擎，确认可生成输出。对应探针 `testRetryPassesOriginalM4AToTheInstalledWhisperEngine`。 |
| 建议修复 | 抽出统一 prepareInput，用于首次导入、重试与启动恢复。检查文件实际可解码性及已完成转换状态，输出到独立临时 WAV，验证成功后原子提交；不能只按扩展名或“文件存在”判断中间文件可用。 |
| 验证方式 | M4A/MOV/MP3/WAV 四类逐项覆盖“只有原始文件”“损坏中间文件”“转换被取消”“转换成功后重试”。转写前应取得有效 WAV，原始文件不改写；错误归因应明确到转换或转写。 |
| 是否 AI 生成典型问题 | 是：首次流程补齐，重试分支复制后遗漏关键步骤；AI 来源不确定。 |
| 本轮实施 | 非WAV重试先归一化 |
| 当前修复位置 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| 当前状态与验收 | 已修复 / 故障回归；testRetryNormalizesM4ABeforeWhisper（使用非零音频） |

### BUG-003：保存失败却返回成功草稿

| 字段 | 内容 |
|---|---|
| ID | BUG-003 |
| 类型 | Bug / AI生成代码 |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [MeetingStore.swift:1988](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1988)，SessionStorage.init；2012，createDraftSession；2038 的 catch；调用方 startRecording:280、importAudio:387 |
| 问题描述 | 数据根创建失败使用 try? 忽略；草稿保存失败又被空 catch 吞掉。函数不返回 Error，只交回 status 为 recording 的对象，调用方无法知道草稿没有保存。 |
| 证据 | 注释声称“let the caller surface the error”，实际没有错误返回通道。探针让 rootURL 指向普通文件，仍返回 recording 草稿，磁盘无 session.json，随后按 ID 获取会话抛错。 |
| 影响 | 可能进入“正在准备录音/导入”后才失败，错误位置偏离真实原因；数据根不可写时，无法保证录音和会话元数据完整保存。没有证明此条件下采集一定持续成功，不能据此声称已录音丢失。 |
| 复现步骤 | 1. 临时目录建立一个普通文件。2. 将它作为 SessionStorage.rootURL。3. 创建 draft。4. 检查返回 recording，而 session.json 不存在。对应探针 `testDraftCreationReturnsSuccessWhenRootIsARegularFile`。 |
| 建议修复 | createDraftSession 改为 throws，目录与元数据都成功后才返回；调用方仅在成功后插入列表和启动采集。把初始化或首次写入错误明确呈现为“会议存储位置不可写”，给出可执行的恢复操作。 |
| 验证方式 | 文件占位、目录只读、权限错误、磁盘空间不足分别注入。都应得到准确错误，录音器未启动、未产生幽灵会议，后续合法操作仍可继续。 |
| 是否 AI 生成典型问题 | 是：注释描述了异常处理，但实现没有实现该契约。 |
| 本轮实施 | 草稿落盘失败抛出并阻止开始录音/导入 |
| 当前修复位置 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| 当前状态与验收 | 已修复 / 故障回归；testDraftCreationReportsDiskFailure |

### BUG-004：读取错误与空列表混为一谈

| 字段 | 内容 |
|---|---|
| ID | BUG-004 |
| 类型 | Bug / UX |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [MeetingStore.swift:1997](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1997)，loadSessions；2117，loadSession；reloadSessions:214 |
| 问题描述 | 扫描数据根失败返回 []，JSON 读取/解码失败返回 nil，再经 compactMap 静默丢弃。用户看到空态或会议缺失，无法区分“没有记录”“没权限读”“一条记录损坏”。 |
| 证据 | `return try? decoder.decode(...)` 与 `items.compactMap`。探针先确认 1 条会议可读，把其 session.json 改成截断 JSON 后，loadSessions 变成 0 条，但文件仍存在。 |
| 影响 | 真实数据被隐藏，用户误以为会议消失，无法在 App 内定位故障、导出原始音频或恢复元数据。该证据不表示文件已经删除。 |
| 复现步骤 | 1. 临时目录创建合法会议。2. 将 session.json 写成 `{truncated`。3. 调 loadSessions 或重新打开使用该数据根的 App。4. 列表遗漏该记录，没有加载问题信息。对应探针 `testCorruptedSessionDisappearsWithoutLoadError`。 |
| 建议修复 | 返回 LoadResult(sessions, issues)，区分根目录失败和单条失败；对确有 session.json 的损坏会议保留恢复入口，展示路径与错误类别。模型目录等非会议目录正常跳过。添加 schemaVersion 和迁移失败保护，迁移前保留备份。 |
| 验证方式 | 混合正常、截断 JSON、字段类型错误、旧版本字段、不可读文件及 models 目录。正常记录照常显示；损坏会议可见且可定位；models 不误报警；扫描根失败不能展示“开始第一场会议”的正常空态。 |
| 是否 AI 生成典型问题 | 是：用 try? 与 compactMap 把错误伪装成无数据；AI 来源不确定。 |
| 本轮实施 | 读取返回损坏目录列表；UI提示并提供数据目录入口，原文件保留 |
| 当前修复位置 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| 当前状态与验收 | 已修复 / 故障回归；testCorruptedSessionIsReportedAndFilePreserved |

### BUG-005：准备开录没有占用任务状态

| 字段 | 内容 |
|---|---|
| ID | BUG-005 |
| 类型 | Bug / 架构 |
| 严重级别 | P1 严重 |
| 置信度 | 高（互斥缺口）；中（实际多路采集与收尾后果） |
| 位置 | [MeetingStore.swift:263](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L263)，startRecording；异步 Task 在 307 创建，isRecording 在 311 才设；importAudio:376；`WorkbenchView.swift:493`、512、553 |
| 问题描述 | startRecording 只拒绝 isRecording/isProcessing，但两者直到 await recorder.start 完成后仍为 false。准备期间第二次开始录音或导入可以通过 guard，覆盖 activeSessionID、mixedSession。开录 Task 未保存，也没有操作 ID 校验，晚到回调会更新共享全局状态。 |
| 证据 | 方法内同步创建 draft 和 recorder，但 `isRecording = true` 位于异步成功分支。导入按钮仅据两个布尔值禁用，主按钮同样按两个布尔值判下一步。不是线程同时写内存，而是 MainActor 在 await 期间的逻辑交错。 |
| 影响 | 可出现多个草稿、会话与录音器错配、旧 Task 清掉新任务状态；是否留下实际录音未收尾取决于系统回调顺序，需用可控录音器或隔离实机验证。 |
| 复现步骤 | 需验证：1. 为录音器 start 注入可等待的假实现。2. 第一次 start 进入准备后保持挂起。3. 第二次 start 或 import。4. 放行旧 start 回调，检查会话数量、活动 ID 与录音器是否错配。当前实现没有录音器注入接口，未以真实会议触发。 |
| 建议修复 | 在第一个 await 前进入 preparing 状态，统一 busy 判定涵盖 preparing/recording/stopping/processing/cancelling；保存开录 Task 与 operationID，回调先核对是否仍属于当前操作。异常时只释放对应操作；录音启动应可取消并保证收尾。 |
| 验证方式 | 连点、准备期间导入/删除、启动失败、晚到成功、晚到失败等确定性顺序测试。只能建立一条有效采集会话；过期操作不能清除新状态；录音器 stop 恰好一次。 |
| 是否 AI 生成典型问题 | 是：把异步开始视为同步完成，仅覆盖正常路径；AI 来源不确定。 |
| 本轮实施 | 异步开始前占用准备状态，阻止重入 |
| 当前修复位置 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| 当前状态与验收 | 已修复 / 注入回归；准备期独占、取消后晚返回、启动期故障通过；首次权限/快速连点仍需实机 |

### BUG-006：写盘丢失音频时间位置

| 字段 | 内容 |
|---|---|
| ID | BUG-006 |
| 类型 | Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高（缺口压缩已复现）；实际双路首包偏移与中断频率需验证 |
| 位置 | [AudioTrackRecorder.swift:77](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/AudioTrackRecorder.swift#L77)，append；144–201，write；[WhisperPipeline.swift:328](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WhisperPipeline.swift#L328) 的“同一个时钟天然对齐”注释 |
| 问题描述 | 样本被按到达顺序连续写入 AVAudioFile，未读取 presentationTimeStamp、补静音、保存起始偏移或识别时间缺口。同一采集时钟只有在时间信息被保留时才能保证双路文件对齐；延迟首包或缺包后，某一路时间会被压缩。 |
| 证据 | 两个合法 0.1 秒缓冲的 PTS 分别为 10.0 和 12.0；写后文件只有 3200 帧 / 0.2 秒，未覆盖首包到末包的 2.1 秒，也没有 failureReason。write 只调用 file.write(from: buffer)，完全不消费 PTS。 |
| 影响 | 时间锚跳回放偏移、两路发言顺序或重叠关系判断错误；串音去重和说话人归属受影响。原始 MOV 被保留，故本项不声称音频原件已永久丢失。 |
| 复现步骤 | 1. 用同格式创建 PTS=10.0/12.0 的两个 1600 帧、16kHz 缓冲。2. append 两次并 finish。3. 读取 CAF 帧数与时长，观察 0.2 秒。探针 testSampleTimestampGapIsRemovedFromRecordedFile。 |
| 建议修复 | 在会话层提供两路共同时间原点；Recorder 按 PTS 计算目标帧位置，首包延迟与间隙补零，重复/重叠帧裁剪或明确失败。若选择保留紧凑文件，必须存完整的时间映射并在转写结果中重映射，不能仅加一个固定偏移解决中途缺口。 |
| 验证方式 | 双路不同首包时间、2 秒缺口、乱序/重复包、长期连续样本及不同采样率均验证。对应同一真实时刻的段在合并后位置一致；与混合原件回放一致；不支持的缺口处理应显式降级。 |
| 是否 AI 生成典型问题 | 是：采样 API 接通，但时间契约遗漏；AI 作者身份不确定。 |
| 本轮实施 | 保存PTS间隔，使用共同host-clock起点；异常时退混合原件 |
| 当前修复位置 | [AudioTrackRecorder.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/AudioTrackRecorder.swift) |
| 当前状态与验收 | 合成验证 / 需实机；testSampleTimestampGapIsPreserved、testSharedEpochPreservesFirstPacketOffsetsAndActualLevels；MOV首包/设备偏移需实测 |

### BUG-007：失败的半条音轨仍参与完整转写

| 字段 | 内容 |
|---|---|
| ID | BUG-007 |
| 类型 | Bug / UX |
| 严重级别 | P1 严重 |
| 置信度 | 高（失败标记和选择条件）；实际系统设备变化后果需验证 |
| 位置 | [AudioTrackRecorder.swift:94](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/AudioTrackRecorder.swift#L94)、114、124；[WhisperPipeline.swift:427](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WhisperPipeline.swift#L427)，makeResult；[MeetingStore.swift:1575](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1575)、1633 |
| 问题描述 | 轨道写入中途出错后停止接收后续样本，但 didWriteAudio 仍为 true。makeResult 只看是否写过帧，不看 failureReason、结束状态或覆盖时长，因而会交出截断的 CAF。两路文件都存在就进入双路转写，未利用完整 MOV 补偿缺失后半场。 |
| 证据 | 先写 16kHz 片段，再输入 48kHz：Recorder 有 failureReason，但 didWriteAudio=true，留下只有首段的文件。makeResult 对这一状态返回非 nil trackURL；失败原因仅进入诊断日志。 |
| 影响 | 发生音频设备/格式变化或写盘错误后，某一方后续发言可能缺失；最终结果仍可能 ready，用户不知道产物不完整。探针验证的是轨道截断与选择标记，并未真正触发 ScreenCaptureKit 设备变化。 |
| 复现步骤 | 1. 同 Recorder 先 append 合法 16kHz PCM。2. 改用 48kHz PCM。3. finish，确认 failureReason 非空但 didWriteAudio 为 true。4. 核对 makeResult 只消费该 true。探针 testFailedTrackStillLooksUsableToResultSelection。 |
| 建议修复 | 区分“有帧”和“完整可用”，产出包含失败原因/覆盖范围的 TrackResult。轨道失败时降级至已验证的混合原件或补转缺失范围，明确展示双路降级/内容不完整；验证补偿完成前不删除仅有的轨道证据。 |
| 验证方式 | 格式切换、写满磁盘、单路丢包、正常静音与 0 帧分别注入。截断轨道不能冒充完整；完整混合原件可用时保住全文；降级提示与实际缺失范围一致。 |
| 是否 AI 生成典型问题 | 是：把“曾经成功”误用作“完整成功”；AI 来源不确定。 |
| 本轮实施 | 失败半轨不作为完整双路输入，保留失败原件及回退提示 |
| 当前修复位置 | [AudioTrackRecorder.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/AudioTrackRecorder.swift) |
| 当前状态与验收 | 合成验证 / 需实机；testFailedTrackIsRejectedForDualTranscription；真实设备切换需验证 |

### BUG-008：后处理无视说话人边界

| 字段 | 内容 |
|---|---|
| ID | BUG-008 |
| 类型 | Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [TranscriptCleaner.swift:132](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/TranscriptCleaner.swift#L132)，collapseRepeats；235–259，mergeBySentence；[MeetingStore.swift:1241](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1241) 在双路合并后调用 clean |
| 问题描述 | 并句不检查 speaker 或间隔，保留首段 speaker；复读折叠也不检查 speaker 和时间。因此已正确标记的两人对话被重新压成一人的发言，或者第二人的独立确认被删掉。 |
| 证据 | local“这笔预算我们还没确认”（无句号）+ remote“我明天提供最终报价。”清洗后为一条 local 段，包含 remote 的承诺。另一个反例是两人相隔 20 秒说“这个方案可以上线。”，最终只剩一段。 |
| 影响 | 待办负责人可能被模型归给错误的一方；原文页不再忠实保存两人表达；证据段、时间范围和对话顺序被改变。 |
| 复现步骤 | 1. 构造不同 speaker 的两段，第一段不以句末符结束。2. 调 TranscriptCleaner.clean。3. 检查段数 1、speaker 仍 local。4. 用相同句子、不同 speaker、相隔 20 秒重复，确认仍被折叠。探针 testCleaningMergesDifferentSpeakersIntoOneLocalSegment。 |
| 建议修复 | 并句必须保持 speaker 一致并限制可解释的时间邻接；复读判断需保留说话人/来源/实际发生时间。跨人确认或真实重复应保留，疑似引擎幻觉用单独标记和可恢复原段处理。 |
| 验证方式 | 我方提问/对方承诺、两人重复确认、同人远隔重复、短相邻碎段、重叠双人发言都覆盖。清洗前后的真实归属不变，独立发言不消失，时间锚保持可核对。 |
| 是否 AI 生成典型问题 | 是：新增 speaker 后旧清洗代码未同步语义；AI 来源不确定。 |
| 本轮实施 | 并句和去重受说话人与相邻时间约束 |
| 当前修复位置 | [TranscriptCleaner.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/TranscriptCleaner.swift) |
| 当前状态与验收 | 已修复 / 回归；testCleaningPreservesDifferentSpeakers、testIndependentRepeatsBySameSpeakerArePreserved |

### BUG-009：相反意见被误判为串音

| 字段 | 内容 |
|---|---|
| ID | BUG-009 |
| 类型 | Bug / AI生成代码 |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [TranscriptMerger.swift:120](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/TranscriptMerger.swift#L120)、143–162，resolve/isSameSpeech/containment |
| 问题描述 | 相似度只统计共享字符，阈值 0.6，并允许较短字符串完全包含在长句中。增加“不”这样的否定词不会降低包含比例到阈值以下，相反意见被视为同一句；随后按置信度只留下一个人的话。 |
| 证据 | 重叠段：“这个方案可以上线。”（0.95）与“这个方案不可以上线。”（0.9），实际 merge 只返回肯定句；反对意见消失。不是仅缺少标点，而是实际决策含义相反。 |
| 影响 | 用户可能把争议误读为达成一致，后续速览/纪要/待办基于不完整且偏向一方的原文生成。 |
| 复现步骤 | 1. local 时间 0–3 秒、肯定句。2. remote 时间 0.1–3.1 秒、否定句。3. 调 TranscriptMerger.merge。4. 结果只有 local 肯定句。探针 testCrosstalkDeduplicationDeletesTheOppositeDecision。 |
| 建议修复 | 最小保护是只去重严格归一化相同、且有可靠声源证据的回声副本；对否定、数字、时间、主体不同的文本保留两条。扩大模糊去重前建立反例集，不能仅提高字符阈值——本例包含比例可达 1。 |
| 验证方式 | 可以/不可以、同意/不同意、15万/50万、今天/明天、我方/对方承担等成对反例必须保留；真实同句串音仍可正确处理且不伪造归属。 |
| 是否 AI 生成典型问题 | 是：用表面字符串相似替代语义一致，happy path 测试掩盖错误。 |
| 本轮实施 | 仅规范化文本精确相同可作为串音候选，保留否定/数字差异 |
| 当前修复位置 | [TranscriptMerger.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/TranscriptMerger.swift) |
| 当前状态与验收 | 已修复 / 回归；testCrosstalkPreservesOppositeDecisions及合并测试；近似串音可能多保留一句，是避免误删的取舍 |

### BUG-010：双路检查点覆盖完整的一路

| 字段 | 内容 |
|---|---|
| ID | BUG-010 |
| 类型 | Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [MeetingStore.swift:1650](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1650)，transcribeDualTracks；1718、1764–1771，transcribeTrack |
| 问题描述 | 两路结果在内存 bySpeaker 中累积，但每个块落盘时把 session.transcriptSegments 直接设为当前一路的 segments。开始保存第二路后，盘上的第一路内容被覆盖，speaker 也尚未标记。失败/退出时“已完成内容”不是双路已完成内容的合集。 |
| 证据 | 构造 601 秒两路 WAV，让 CLI 成功输出我方两块、对方第一块，在对方第二块退出 42。最终 failed 的 session.json 仅含“对方第一段内容”，无“我方已经完成的内容”，speaker 全 nil。分块 JSON 仍可能在磁盘，故不是音频原件永久丢失。 |
| 影响 | 失败界面无法展示已经完成的完整部分，恢复证据与进度不一致；启动恢复的双路路径从头重跑，不利用已产出的两路检查点，增加重复等待。 |
| 复现步骤 | 1. 临时会话带 local.wav/remote.wav，各 601 秒。2. 注入 CLI 使第二路第二块失败。3. 调实际 retryProcessing 并等待 failed。4. 读 JSON，观察只剩第二路首块。探针 testSecondTrackCheckpointOverwritesTheCompletedFirstTrack。 |
| 建议修复 | 按 source/speaker 分别持久化 segments、已完成块和时间覆盖范围；可见逐字稿由两路已完成片段合并派生，每块保存应保留另一来源。保存错误必须向上抛，不用 try? 掩盖。恢复按两路独立检查点续跑，并明确标记部分结果。 |
| 验证方式 | 在两路每个块之前/之后注入失败与退出，重启后可见所有已完成块及正确 speaker。续跑只处理未完成块，结果与一次成功处理一致；盘满时明确失败而非显示未保存结果。 |
| 是否 AI 生成典型问题 | 是：单路检查点实现被复用到双路，存储语义未同步改变。 |
| 本轮实施 | 第二路检查点合入第一路已完成结果 |
| 当前修复位置 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| 当前状态与验收 | 已修复 / 故障回归；testSecondTrackFailurePreservesFirstTrackCheckpoint |

### BUG-011：旧任务收尾破坏新任务状态

| 字段 | 内容 |
|---|---|
| ID | BUG-011 |
| 类型 | Bug / 架构 |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [MeetingStore.swift:1060](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1060)，deleteSession；1365–1403，failProcessing/cancelFinishedProcessing；[WhisperPipeline.swift:792](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WhisperPipeline.swift#L792)、844，LocalProcessRunner.run 清理 |
| 问题描述 | 删除旧任务取消异步工作后立即允许新任务开始；旧 catch/收尾没有核对任务 token，就清空全局 busy、processingTask 与 activeSessionID。进程包装器也会在旧 run 的 defer 中无条件清 activeProcess，可能清掉新进程句柄。 |
| 证据 | A 的 CLI 延迟响应 SIGTERM；删除 A，开始 B，B 的 CLI 已运行且 session.status=processing；释放 A 后，Store.isProcessing 变成 false，而 B 仍未结束。最后放行 B 仍可完成 ready，证明当时不是 B 已完成。 |
| 影响 | UI 错误显示空闲、停止按钮失去作用、再次允许录音/导入；实际运行与界面状态分离。旧异步 cancel 调用也可能作用到新进程，需要同一轮归属保护。 |
| 复现步骤 | 1. 开始 A，等待测试 CLI 启动。2. 删除 A，立即开始 B。3. 等 B 启动但保持阻塞。4. 只放行 A 的退出。5. 检查 B 的盘上状态仍 processing，而 Store 已 false。探针 testDeletedOldTaskClearsNewTaskBusyState。 |
| 建议修复 | 为每个操作与每次子进程 run 分配唯一 ID；旧操作可处理自己资源，但不能更新新操作全局状态。cancel 应明确指定目标 run，不使用共享“当前进程”取消任意对象。取消/删除可先进入 cancelling，再等对应工作收尾；若允许新工作并行，需分离完整上下文。 |
| 验证方式 | A 正常/失败/取消晚到，B 已开始；A/B 交错删除；取消后立即重试与重新整理，都用可控屏障测试。B 状态不被 A 改写，取消只终止指定进程，旧任务清理不删新句柄。 |
| 是否 AI 生成典型问题 | 是：共享状态的异步回调没有任务归属校验；AI 来源不确定。 |
| 本轮实施 | 终态回调校验任务所属；旧任务退出后释放并删除；取消归属当前进程 |
| 当前修复位置 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| 当前状态与验收 | 已修复 / 竞态回归；testDeletionWaitsForOldTaskBeforeStartingAnother |

### BUG-012：超时和取消没有进程退出上限

| 字段 | 内容 |
|---|---|
| ID | BUG-012 |
| 类型 | Bug |
| 严重级别 | P1 严重（外部 CLI 无法正常退出时触发） |
| 置信度 | 高（SIGTERM 反例）；未等待真实 12 分钟计时器触发 |
| 位置 | [WhisperPipeline.swift:823](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WhisperPipeline.swift#L823)、841、864，LocalProcessRunner.run/cancel；[MeetingStore.swift:1507](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1507)，transcribeChunkWithTimeout |
| 问题描述 | 取消只发 terminate/SIGTERM，continuation 要等 terminationHandler。没有宽限期、强制结束或可确保完成的收尾协议。超时 task group 的 cancelAll 也要等子任务完成，不能凭计时器抛错保证整体调用及时返回。 |
| 证据 | 合成 CLI 明确忽略 SIGTERM；取消 Task 并调用 runner.cancel 后，300ms 检查进程仍活着，任务仍等待。之后探针发送 SIGKILL 才能结束。持续等待结论由无限 CLI 与无退出上限代码共同支持，而不是声称实测了无限时间。 |
| 影响 | 用户长时间停在“正在停止处理”，无法开始下一场；预设超时不能在此条件下释放状态和资源。挂住 CLI 也可能持续占 CPU/内存。 |
| 复现步骤 | 1. 临时 CLI 安装 SIGTERM 忽略处理器后循环。2. 用实际 WhisperCLIRunner 执行。3. task.cancel 并 runner.cancel。4. 检查仍活着且任务未完成；测试自行强制结束以清理。探针 testCancellationDoesNotFinishIfCLIRejectsSIGTERM。 |
| 建议修复 | 对自己启动的确切进程先请求终止，短宽限期后若仍活着再强制结束，并等待/reap；保留进程身份与有锁的一次性 continuation 完成状态，防重复恢复。考虑进程组/子进程边界，退出流程必须在有限时间内完成。 |
| 验证方式 | CLI 正常退出、立即退出、忽略 TERM、TERM 时延迟退出、启动前取消、结束与取消竞态都验证。超过取消时限应结束对应进程并清状态；无遗留子进程，无 continuation 双重恢复。 |
| 是否 AI 生成典型问题 | 是：计时器与 cancel 调用表面齐全，却未保证底层工作可取消。 |
| 本轮实施 | 启动/取消过锁，TERM后1秒KILL |
| 当前修复位置 | [WhisperPipeline.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift) |
| 当前状态与验收 | 已修复 / 故障回归；testCancellationFinishesEvenIfCLIRejectsSIGTERM；真实长超时未等待 |

### BUG-013：删除活动录音未停止采集

| 字段 | 内容 |
|---|---|
| ID | BUG-013 |
| 类型 | Bug / 安全（录音生命周期） |
| 严重级别 | P1 严重 |
| 置信度 | 高（没有 stop 调用）；中（删除后真实系统采集表现需验证） |
| 位置 | [MeetingStore.swift:1060](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1060)，deleteSession；stopRecording:324；[WorkbenchView.swift:248](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WorkbenchView.swift#L248) 的会议菜单始终提供删除 |
| 问题描述 | 活动会话是 recording 时，deleteSession 只取消处理任务与录音上限计时，把 isRecording=false，再删除文件目录。它没有停止 mixedSession/microphoneSession，也没有释放这些录音器引用。后续 stopRecording 又因 isRecording=false 被 guard 拒绝。 |
| 证据 | 删除分支只有 transcriber.cancel/transcoder.cancel；实际录音由 MixedRecordingSession 的 stream 持有，停止需要 stop()/stopCapture。录音期间 processingTask 通常为空，因此取消处理任务不能替代停止采集。 |
| 影响 | 可能在 UI 显示空闲、目录已删除之后继续使用屏幕/麦克风采集资源；文件收尾失败，后续录音重入。是否持续实际采集、持续多久，需在隔离系统录音中验证。 |
| 复现步骤 | 需实机验证：1. 隔离数据根开始短合成/环境录音。2. 从会话菜单删除当前录音。3. 检查系统采集指示与进程/文件句柄是否消失。4. 检查后续停止/新录音行为。本批未对用户真实录音执行删除。 |
| 建议修复 | 活动 recording/preparing 的删除要先完成对应录音器取消/stop 与文件关闭，再删除数据并更新 UI；失败时保留明确的 stopping/error 状态。最小临时保护是禁用活动录音的删除入口，并提供“停止后删除”。 |
| 验证方式 | 开录准备期、稳定录音、正在停止及停止报错分别尝试删除。确认采集终止、句柄关闭、取消上限计时不留下孤立录音器，新录音不会与旧采集并存。 |
| 是否 AI 生成典型问题 | 是：删除与转写取消共用分支，遗漏真实录音对象的资源生命周期。 |
| 本轮实施 | 活动录音/准备中的删除被拒绝，必须先停止保存 |
| 当前修复位置 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| 当前状态与验收 | 已修复 / 注入回归；准备期活动会议删除被拒绝、任务状态保留；真实采集中删除未实测 |

### BUG-014：系统采集故障不即时上报

| 字段 | 内容 |
|---|---|
| ID | BUG-014 |
| 类型 | Bug / UX |
| 严重级别 | P1 严重 |
| 置信度 | 高（代码路径）；中（真实系统故障显示需验证） |
| 位置 | [WhisperPipeline.swift:448](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WhisperPipeline.swift#L448)、455，recordingOutput(_:didFailWithError:)/stream(_:didStopWithError:)；finishStopIfPossible:462；[MeetingStore.swift:301](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L301) 的录音器接线 |
| 问题描述 | 采集错误仅保存为 stopError 并调用 finishStopIfPossible；后者第一句要求 stopRequested。如果错误在正常录音期间发生，直接返回，没有向 Store 发布失败，也没有主动停止并保存已录部分。Store 保持录音状态，计时与装饰柱形仍可继续。 |
| 证据 | `guard stopRequested else { return }` 在错误处理前；MixedRecordingSession 没有对 Store 的错误事件出口。启动成功后，Store 仅依赖用户 stop 的结果发现错误。源码路径确定，未制造真实系统故障。 |
| 影响 | 采集已经中断而用户以为仍录着，直到结束会议才得知失败，无法在发生时采取恢复措施。与第一批 UX-001 假信号表叠加，但本项根因是错误传播缺失。 |
| 复现步骤 | 需验证：用可注入流适配器或隔离实机在录音期间触发采集失败，保持 stopRequested=false。检查 Store 是否即时进入失败/中断状态、保存现有内容与给出恢复动作。本批仅追踪了代码，没有把系统错误发生率当事实。 |
| 建议修复 | 录音器提供明确的 started/stopped/interrupted/failed 事件接口；错误事件无需等待用户 stop。Store 收到后只更新对应 operation，停止剩余采集、保留可恢复文件、展示原因和下一步。避免递归 stop 或重复 resume。 |
| 验证方式 | 正常采集中断、输出失败、启动期间失败、stop 与失败同时发生四类顺序均测。界面即时停止计时/错误信号，错误只报告一次，部分录音可恢复，后续操作不被旧回调污染。 |
| 是否 AI 生成典型问题 | 是：实现了 delegate 方法，却只覆盖“用户主动停止”的错误出口。 |
| 本轮实施 | 采集异常即时通知Store，收尾有10秒超时 |
| 当前修复位置 | [WhisperPipeline.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift) |
| 当前状态与验收 | 已修复 / 注入回归；准备期/采集期中断、重复回调与旧任务回调通过；真实掉设备故障需实测 |

### BUG-015：分块归属丢弃边界句子的后半段

| 字段 | 内容 |
|---|---|
| ID | BUG-015 |
| 类型 | Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高（构造输出处理结果）；中（真实引擎出现频率未测） |
| 位置 | [MeetingStore.swift:1788](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1788)，chunkWindow；1800，ownedSegments；1193、1759 的调用 |
| 问题描述 | 起点早于当前 coreStart 的段一律归前块；但前块只多读 2 秒，未必包含该段的完整结尾。下一块得到同一长句更完整的结果后仍丢掉整个段，尾部没有任何块保留。原有“每段恰好归一块”测试使用同一份人工时间线，未覆盖两次转写的文本与分段不同。 |
| 证据 | 第一块实际读到 602 秒，输出 599–602“下周一”；第二块从 598 秒读，输出 599–606“下周一交付最终报价单。”。实际 ownedSegments 拼合只留下“下周一”。这是合法窗口内的构造转写输出，没有宣称来自实测语音。 |
| 影响 | 恰好跨 10 分钟切点的长句，可能丢掉完整待办、数字或条件；全文仍顺畅，错误不显眼。原始音频保留，能够重新转写核查。 |
| 复现步骤 | 1. 建立 1200 秒音频的前两块窗口。2. 给前块注入 599–602 截断段，后块注入 599–606 完整段。3. 分别调用 ownedSegments 再拼接。4. 确认只剩截断段。探针 testChunkOwnershipDiscardsTheMoreCompleteBoundarySentence。 |
| 建议修复 | 边界采用时间覆盖与文本/token 重叠对齐，合并截断段与更完整的新段，保证前块读取终点之后的内容不丢；维护原始块输出以便核对。不能仅放宽起点过滤后重复全文，也不能只增加固定重叠时长而不处理任意长句。 |
| 验证方式 | 在切点前 1–2 秒开始、切点后 3–10 秒结束的句子，分别模拟相同/不同分段与文本截断。全部独有内容保留且不重复，时间顺序正确；再用真实中文音频验证该类边界。 |
| 是否 AI 生成典型问题 | 是：测试钉住现有公式，却未验证“完整内容不丢”的真实契约。 |
| 本轮实施 | 保留跨core边界完整句，不再仅按start丢弃 |
| 当前修复位置 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| 当前状态与验收 | 已修复 / 回归；testChunkOwnershipPreservesTheCompleteBoundarySentence；相邻解码略异的句子可能重复保留 |

### BUG-016：人工校正后旧整理结果没有过期状态

| 字段 | 内容 |
|---|---|
| ID | BUG-016 |
| 类型 | Bug / UX |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [MeetingStore.swift:776](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L776)，updateTranscriptSegment；[WorkbenchView.swift:1013](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WorkbenchView.swift#L1013)，速览；[MeetingExport.swift:31](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingExport.swift#L31)，markdown |
| 问题描述 | 原文编辑更新分段、全文和 transcriptEditedAt，却保留旧 analysis，没有输入版本关联或过期标志。速览/纪要不消费编辑时间，导出也不提示旧结果基于修改前的材料。 |
| 证据 | 合成会议从“下周一交付”保存为“改为下周三交付”，原文显示“已人工校正 1 处”；速览、待办截止和纪要仍为下周一。实际 UI 导出同时含旧纪要与新原文，无过期提示。探针断言 analysis 与旧值完全相同、noticeMessage=nil。 |
| 影响 | 用户或收件人把旧决策、日期、金额、负责人当成校正后的结论执行；仅在原文页出现的校正标记不足以提醒阅读速览/纪要的人。 |
| 复现步骤 | 1. 使用有 6 段、足量文字、非本地规则模型来源的合成已完成会议。2. 修改涉及结论的第一句并保存。3. 打开速览/纪要并导出。4. 对照原文，确认旧日期仍呈现为当前结论。对应 testEditedTranscriptExportStillPresentsContradictoryOldMinutesWithoutWarning。 |
| 建议修复 | 保存原文 revision 或材料 hash，并在生成 analysis 时保存其 inputRevision；不匹配时保留旧结果但明确标“原文已更新，此结果待重新整理”。三页、复制、导出共用这一判据。用户主动重新整理成功后提交新版本；不要为消除过期标记自动向云端发送原文，也不要直接清空旧结果。 |
| 验证方式 | 校正日期、数字、否定意见后各结果页与导出均有过期状态；拒绝/无变化编辑不标过期；重整理失败/取消保留旧结果与过期提示；成功后 inputRevision 匹配才清标记。 |
| 是否 AI 生成典型问题 | 是：输入编辑实现完整，派生产物失效契约遗漏；作者来源不确定。 |
| 本轮实施 | 校正置analysisStale；原文变更后双页/复制/导出统一标过期 |
| 当前修复位置 | [MeetingModels.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingModels.swift) |
| 当前状态与验收 | 已修复 / UI与回归；AuditDeliveryTests与upgrade-ui-overview.png / minutes-ax.txt |

### BUG-017：全文型历史记录在原文页被隐藏

| 字段 | 内容 |
|---|---|
| ID | BUG-017 |
| 类型 | Bug / UX |
| 严重级别 | P1 严重（transcriptText 非空且 transcriptSegments 为空时） |
| 置信度 | 高；用户存量数据中该形态的数量未统计 |
| 位置 | [WorkbenchView.swift:1574](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WorkbenchView.swift#L1574)，WorkbenchOriginalDocument；[MeetingStore.swift:218](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L218)，reloadSessions；[MeetingExport.swift:281](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingExport.swift#L281)，transcriptAppendix 的全文回退 |
| 问题描述 | 原文页只看分段数组，为空就写“转写还没有内容”，没有读 transcriptText 的回退。材料门禁也只评估分段，进一步可能显示“没有识别到发言”。导出却支持全文回退，说明同一合法数据形态在各入口不一致。 |
| 证据 | UI 合成夹具有完整 transcriptText，原文页显示“转写还没有内容”，速览引导到原文确认。探针保留 620 字全文，加载后全文逐字不变、分段为空、生成 no-speech 材料状态；Exporter 可以导出那 620 字。 |
| 影响 | 用户无法在核心原文界面阅读已经保存的全文，误以为未转写，可能进行不必要重试；这不是磁盘内容被删除。 |
| 复现步骤 | 1. 临时 ready 会议写非空 transcriptText、空 transcriptSegments。2. 打开原文。3. 观察空态。4. 用同会话导出，与磁盘全文对照。对应 testLegacyTextSurvivesButMaterialGateTreatsItAsNoSpeech。 |
| 建议修复 | 分段为空但全文非空时以普通可选择文本展示，明确无时间锚/分段编辑能力；空态必须在两个文本来源均为空时才出现。材料门禁与旧分析修补也应识别全文来源，不能按空数组宣称没有发言；需时间锚时让用户另行选择重新转写，先保留全文。 |
| 验证方式 | 分段版、仅全文版、全文空白、完全空、旧 schema 各一场。全文版可以阅读/复制/导出，不伪造时间戳、不被修补清空，重试失败不损失原文。 |
| 是否 AI 生成典型问题 | 是：新分段界面完成，但兼容回退只在导出实现；作者来源不确定。 |
| 本轮实施 | 历史全文仍可阅读/选择/导出，整理用保守materialSegments回退 |
| 当前修复位置 | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| 当前状态与验收 | 已修复 / UI与回归；upgrade-ui-legacy.png及历史全文测试 |

### BUG-020：流式响应没有结束证据也宣称完成

| 字段 | 内容 |
|---|---|
| ID | BUG-020 |
| 类型 | Bug / AI生成代码 |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [SummaryEngine.swift:1072](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L1072)，performStreamingRequest；[SummaryEngine.swift:1094](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L1094)，truncated；[SummaryEngine.swift:822](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L822)，SummaryTextResult.isComplete；[SummaryEngine.swift:498](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L498)，partial 判定 |
| 问题描述 | parser 遇 DONE 直接 break，但不保存是否收到终止事件；读取 EOF 时只要 accumulated 非空且 finish_reason 不等于 length，就被 isComplete 接受。代理或服务以合法 HTTP EOF 提前结束 SSE 后，半句纪要会被标作完整。正常网络抛 URLError 的断线不属于这个复现；此处是内容协议没有完成但传输正常结束。 |
| 证据 | /eof 路由只发送一条 content delta，没有终止 choice、finish_reason、DONE。facts 给合法 JSON，minutes 给“合成纪要只输出了半句，后续内容尚未生成”。实际返回保留半句、partialNotice=nil、diagnostics.partial=false、minutesFinishReason=nil，仅 2 次请求。 |
| 影响 | 核心结果看起来已经成功，用户不知道后面的决策或行动可能缺失；直接分享会把不完整内容当正式纪要。无需依赖 JSON 解析失败才能触发。 |
| 复现步骤 | 1. 本批服务器使用 eof 路由。2. Engine.analyze 输入足量合成分段。3. 服务只发送内容后关闭合法响应体。4. 检查 text 与 partial/finishReason。对应 testPrematureSSEEOFIsAcceptedAsCompleteMinutes。 |
| 建议修复 | 显式建模流结束状态：协议成功终止、token 上限、内容过滤/拒绝、未确认 EOF、解析失败。按受支持协议判断完成，不能以非空文字推断成功。至少在无成功 finish_reason 且无协议终止标记时标未完成；保留已收到文本并提示中断。不要把所有不完整都说成 token 上限，也不要自动无上限重生成。兼容某些只给 DONE 或只给 stop 的服务应写明确适配规则和测试。 |
| 验证方式 | 测完整 stop+DONE、仅协议允许的 stop、仅协议允许的 DONE、无终止 EOF、有/无正文、畸形 event、length、content_filter、真实连接异常与取消。未确认 EOF 必须有部分结果状态，UI/复制/导出可见；合法结束不误报。重试失败保留旧可用结果。 |
| 是否 AI 生成典型问题 | 是：针对 length 的局部修复遗漏整体流状态机；已有注释声称检查截断，实际覆盖范围更窄。作者来源不确定。 |
| 本轮实施 | SSE结束需DONE/finish证据，EOF/坏事件标partial且不额外重新生成 |
| 当前修复位置 | [SummaryEngine.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift) |
| 当前状态与验收 | 已修复 / 协议回归；testPrematureSSEEOFIsMarkedPartial：partial=true、unconfirmed_eof |

### BUG-022：时间锚解析与显示可能整数溢出崩溃

| 字段 | 内容 |
|---|---|
| ID | BUG-022 |
| 类型 | Bug |
| 严重级别 | P1 严重（极端时间输入） |
| 置信度 | 高：整数溢出代码路径确定 |
| 位置 | [MeetingModels.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingModels.swift) |
| 问题描述 | 时间锚解析与显示可能整数溢出崩溃 |
| 证据 | 基线OverviewBullet对Int值乘60/3600后转TimeInterval，Int.max分钟会先溢出；clockLabel直接Int(self.rounded())不能处理非有限/超大Double。 |
| 影响 | 损坏记录、极端模型时间字段可使解析或显示trap，阻断打开相应会议。没有认定真实云端已返回这种字段。 |
| 复现步骤 | 1. 构造[Int.max:59]时间锚及infinity/NaN clockLabel。2. 调解析显示。3. 基线静态可确定trap条件；升级用回归测试验证不崩溃。 |
| 建议修复 | 已先转Double再计算，显示时先检查finite并钳制Int转换范围。 |
| 验证方式 | AuditDeliveryTests中极端timestamp回归通过；普通秒、分钟、小时旧测试仍通过。 |
| 是否 AI 生成典型问题 | 是：happy path掩盖数值边界，作者来源不确定 |
| 本轮实施 | 时间计算Double先行，显示保护非有限/超大值 |
| 当前修复位置 | [MeetingModels.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingModels.swift) |
| 当前状态与验收 | 已修复 / 边界回归；极端timestamp测试；原trap是确定数值路径，不代表真实线上触发 |

### BUG-023：导入input.wav会与标准化输出重名并替换本机副本

| 字段 | 内容 |
|---|---|
| ID | BUG-023 |
| 类型 | Bug / 数据完整性 |
| 严重级别 | P1 严重（保留原件受损） |
| 置信度 | 高：合成afconvert实测 |
| 位置 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| 问题描述 | 导入input.wav会与标准化输出重名并替换本机副本 |
| 证据 | 基线按用户文件名保存原件，再转换到同目录input.wav。import-filename-collision.log：48kHz双声道合成原件同路径afconvert退出0，文件变成16kHz单声道，SHA256改变。用户选择目录外的原文件未改动。 |
| 影响 | 应用内原音频副本丢失原采样率/声道，回放和后续修订只剩降采样音频；不能宣称所有input.wav导入必失败。 |
| 复现步骤 | 1. 合成48kHz双声道input.wav。2. 导入副本按原名落盘。3. 相同路径转16kHz单声道。4. 对比RIFF头和SHA。 |
| 建议修复 | 已将保留文件名input.wav（大小写归一比较）改存imported-original.wav；禁止session.json覆盖；相同源目标不删除源。 |
| 验证方式 | testImportedInputWAVPreservesOriginalAndManifest验证分离目标、原件字节和清单仍可读。 |
| 是否 AI 生成典型问题 | 是：两个看似合理路径未验证组合，作者来源不确定 |
| 本轮实施 | input.wav保留名改存，避免原件与归一化同名；清单名禁止覆盖 |
| 当前修复位置 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| 当前状态与验收 | 已修复 / 文件回归；原始48k双声道同名转换确实改写副本；修复后原件字节保留 |

### BUG-024：安装前强制结束App，且未完成复制就移走旧版

| 字段 | 内容 |
|---|---|
| ID | BUG-024 |
| 类型 | Bug / 数据安全 |
| 严重级别 | P1 严重（安装脚本） |
| 置信度 | 高：脚本与隔离故障测试 |
| 位置 | [Scripts/install_app.sh](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/install_app.sh) |
| 问题描述 | 安装前强制结束App，且未完成复制就移走旧版 |
| 证据 | 基线install_app使用killall，然后移旧App到Trash，再ditto新App。新测试仅临时假应用：运行中、复制失败、签名失败、最终替换失败、成功备份五场景均通过。未对真实录音进程发送终止。 |
| 影响 | 录音/处理可能被安装强制打断；复制失败时原安装路径丢失有效App。真实录音损坏是需验证后果。 |
| 复现步骤 | 1. 阅读killall/先mv后ditto顺序。2. 使用PATH假命令注入上述失败。3. 检查安装路径与旧版版本标记。 |
| 建议修复 | 已拒绝运行中的App（构建前与替换前各检查一次）；目标卷先完整复制验签，再留旧版备份后替换；失败回滚旧版。 |
| 验证方式 | python3 Scripts/tests/test_safe_install.py：5测试通过，原件保存、失败恢复、暂存清理。未运行真实安装。 |
| 是否 AI 生成典型问题 | 是：只实现成功路径，作者来源不确定 |
| 本轮实施 | 不终止运行App；先复制验签、保留旧版、失败回滚 |
| 当前修复位置 | [Scripts/install_app.sh](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/install_app.sh) |
| 当前状态与验收 | 已修复 / 隔离故障回归；5个临时假应用安装场景；未运行真实安装 |

### BUG-025：静音门禁覆盖不一致与轻声信号误过滤

| 字段 | 内容 |
|---|---|
| ID | BUG-025 |
| 类型 | Bug / AI生成代码 |
| 严重级别 | P1 严重 |
| 置信度 | 高：内置真实引擎全零音频实测、代码分支与合成回归 |
| 位置 | MeetingStore.swift，process单路分支与transcribeDualTracks；WhisperPipeline.swift，AudioLevelProbe.hasAudibleSignal |
| 问题描述 | 双路有静音探针，导入/混合回退单路没有。双路探针固定0.01峰值阈值，低于它的合法信号也会被整路排除。 |
| 证据 | upgrade-runtime-smoke.log：全零合成WAV被包内small模型解码成“我看你很想念你…”；同一来源的单路process此前直接送CLI。原threshold=0.01；0.005合成正弦信号属于非零音频却低于旧阈值。未声称这段正弦就是真实语音。 |
| 影响 | 静音产生虚构逐字稿，轻声通道可能完全缺失。实际复杂噪声与语音识别准确率尚未测。 |
| 复现步骤 | 1. 生成1秒16kHz全零音频，直接调用内置引擎。2. 检查JSON/日志文字。3. 比较单/双路处理入口。4. 构造峰值0.005的非零音频测试探针。 |
| 建议修复 | 已统一使用“数字全零才可跳过”的保守探针，并覆盖单路；读取失败不冒充无发言。噪声中语音判定需要另做VAD质量评测，不用振幅阈值代替语音检测。 |
| 验证方式 | testSingleTrackDigitalSilenceSkipsCLIAndQuietSignalStillReachesCLI：静音配必失败CLI仍ready且原文为空，0.005信号必须到达CLI并报告失败；testProbeTreatsQuietButRealSpeechAsAudible改用0.005，仍可转写。真实引擎直接调用仍可能幻觉，此修复是App入口门禁，不是声称修复模型本身。 |
| 是否 AI 生成典型问题 | 是：单路/双路行为分叉不一致、振幅被用作语音判定；作者来源不确定 |
| 本轮实施 | 单路加入数字静音门禁，双路不再用-40dB阈值丢弃弱信号 |
| 当前修复位置 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| 当前状态与验收 | 已修复 / 回归；真实噪声待验；testSingleTrackDigitalSilenceSkipsCLIAndQuietSignalStillReachesCLI及0.005探针测试；模型本身仍可能幻觉 |

### SEC-002：云端正文跟随跨来源重定向

| 字段 | 内容 |
|---|---|
| ID | SEC-002 |
| 类型 | 安全 |
| 严重级别 | P1 严重 |
| 置信度 | 高：不同端口来源实测；其他来源组合需验证 |
| 位置 | [SummaryEngine.swift:880](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L880)，makeRequest；[SummaryEngine.swift:1038](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L1038)，performStreamingRequest；[SummaryEngine.swift:1149](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L1149)，performBufferedRequest |
| 问题描述 | 会议原文放入 POST body，通过 URLSession.shared 发出，没有应用级重定向范围控制。配置来源返回 307 后，系统继续把原 body 发往另一来源，应用没有拒绝或要求用户另行配置目的地。来源按 scheme、host、有效 port 判定，不只是主机名。 |
| 证据 | 配置 origin=127.0.0.1:端口A，307 Location=127.0.0.1:端口B。B 实际收到 2 个 POST，速览和纪要的正文都含 REVIEW_SYNTHETIC_MEETING_MARKER。日志 `authorization forwarded=false`：本次系统移除了 Authorization，不能据此声称 key 泄漏，也不能认为正文因此受到保护。 |
| 影响 | 网关配置错误或被篡改时，敏感会议内容流向用户未配置的来源。需要原服务返回重定向；不宣称攻击者能在没有此前提时主动读取会议。 |
| 复现步骤 | 1. 用本批服务建立两个 loopback 端口。2. SummaryEngine.analyze 指向 A 的 redirect 路由，传合成分段。3. A 返回 307 到 B。4. 在 B 请求记录中检查原文 marker。对应 testCrossOrigin307ForwardsSyntheticMeetingAndAuthorization。 |
| 建议修复 | 为生成与模型发现统一使用专用 URLSession 和 redirect delegate。拒绝 scheme/host/有效 port 改变以及 HTTPS 降级；若不需要重定向，直接禁用。允许的同来源跳转也应限制次数。被拒绝时显示可操作提示，让用户自行核对并重新配置地址；不要把已返回的不同目的地自动设为新地址。只检查最终 response.url 太晚，正文可能已经转发。 |
| 验证方式 | 测试 301/302/303/307/308、不同 host/port、HTTPS→HTTP、循环跳转以及取消。被拒绝的目标不得收到任何合成正文或 Authorization；同来源的允许情形正常完成；生成和 /models 共用策略。跨协议、跨主机应在受控环境另测。 |
| 是否 AI 生成典型问题 | 是：请求实现完整，但把敏感请求的信任范围交给系统默认行为；作者来源不确定。 |
| 本轮实施 | scheme/host/有效port不同即拒绝；生成和模型发现统一专用ephemeral session |
| 当前修复位置 | [SummaryEngine.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift) |
| 当前状态与验收 | 已修复 / 真实loopback；testCrossOrigin307DoesNotForwardMeetingOrCredentials：目标零请求；HTTPS/跨主机矩阵待补 |

### SEC-003：会话清单能改变数据根之外的操作目标

| 字段 | 内容 |
|---|---|
| ID | SEC-003 |
| 类型 | 安全 / Bug |
| 严重级别 | P1 严重（条件性：本地 manifest 被篡改、错误迁移或目录存在异常链接） |
| 置信度 | 高；未发现远程 JSON 导入入口 |
| 位置 | [MeetingStore.swift:2117](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L2117)，loadSession；[MeetingStore.swift:2058](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L2058)，save；[MeetingStore.swift:2064](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L2064)，delete；[MeetingStore.swift:2071](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L2071)，folderURL/sourceURL/inputURL |
| 问题描述 | 读取目录下的 session.json 后，代码信任其 folderName，而不是检查其与实际目录一致。save/delete 直接拼接这个值，既未拒绝 `..` 或路径分隔符，也未限制解析后的目标。符号链接同样能将保存导向根外。音频 preferredFileName 也没有单组件范围校验，应在同一次修复中处理。 |
| 证据 | 将临时合法清单 folderName 改成 `../outside-victim`，从真实 loadSessions 读入后 delete，临时兄弟目录及 sentinel 被删，原会议目录仍在。第二探针建立 meetings/link→兄弟 outside-write，save 把 session.json 写进兄弟目录。所有牺牲目录均由夹具创建。音频字段逃逸本批为静态观察，未另行宣称实际泄漏。 |
| 影响 | 正常 UI 删除会议可能删到 App 用户权限允许访问的其他目录；保存可能写错位置。没有提权、没有远程无需交互攻击证据，也不表示常规自动创建的正常目录会越界。 |
| 复现步骤 | 1. 在临时根创建会议目录与兄弟 sentinel 目录。2. 仅修改该临时 session.json 的 folderName。3. 调用 loadSessions，再 delete。4. 检查兄弟目录消失。符号链接探针单独验证 save。对应 testManifestPathTraversalDeletesOutsideDataRoot / testSymlinkAllowsSessionWriteOutsideDataRoot。 |
| 建议修复 | 建立会抛错的统一路径解析入口，folderName 和音频名必须是非空单一文件名组件，拒绝 `.`, `..`, 分隔符与绝对路径。load 时核对 manifest.folderName 等于所枚举的实际目录名，异常记录隔离并提示，不能静默修成任意路径。解析符号链接后按路径组件核对边界：会议目录必须是 canonical root 的直接子目录，音频必须在已验证的会议目录内；拒绝会话目录符号链接。不要只用字符串 hasPrefix(root.path)，它会误认同前缀兄弟目录。删除前重新校验目标；如把恶意本地并发换链也纳入威胁模型，需使用文件描述符相对操作避免 TOCTOU。 |
| 验证方式 | 在临时目录验收正常会话、清单目录名不一致、`../`、绝对路径、同前缀兄弟目录、目录/文件符号链接、缺失目标。任何非法操作应抛可识别错误，根外 sentinel 不变；正常删除只删除一个会话。异常文件保留给恢复，不能为测试而触碰真实会议根。 |
| 是否 AI 生成典型问题 | 是：happy path 文件拼接正确，持久化输入和删除范围校验遗漏；作者来源不确定。 |
| 本轮实施 | 限制路径单组件，拒绝symlink，核对实际目录/清单ID；写/删校验根 |
| 当前修复位置 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| 当前状态与验收 | 已修复 / 故障回归；manifest ../不能删根外；symlink不能写根外。未宣称抵御同机恶意进程的TOCTOU竞态 |

### SEC-004：原始服务端错误污染会议文件与导出

| 字段 | 内容 |
|---|---|
| ID | SEC-004 |
| 类型 | 安全 |
| 严重级别 | P1 严重（条件性：服务或代理错误体回显敏感信息） |
| 置信度 | 高：假密钥回显链路实测；真实服务回显概率未知 |
| 位置 | [SummaryEngine.swift:1212](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L1212)，responseMessage；[SummaryEngine.swift:1200](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L1200)，rawSnippet；[MeetingStore.swift:1338](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L1338)，buildAnalysis；[MeetingExport.swift:35](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingExport.swift#L35)，markdown；[MeetingStore.swift:652](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L652)，模型发现错误日志 |
| 问题描述 | 服务端 error.message/code/type 与原样响应片段只裁剪长度，没有脱敏。非 401/403/404 的错误可经 localizedDescription 放入 fallback.summaryError，再写入 session.json 并作为 notice 导出。另一个发现路径以 privacy.public 记录 String(describing:error)，即使友好文案隐藏 401 信息，也可能仍记录其原始 associated value；该日志分支是静态证据。 |
| 证据 | loopback 服务返回 HTTP 500，error.message 含 `debug Authorization: Bearer REVIEW_SYNTHETIC_CREDENTIAL_NOT_A_REAL_KEY`。使用真实 regenerateSummary 后，重新从磁盘读出的 summaryError 和 MeetingExporter.markdown 均含该假 key。对应测试通过；未把原始运行日志中的真实敏感信息作为材料。 |
| 影响 | 仅用于认证的秘密可能被复制成普通会议内容，随着分享、备份、问题反馈或日志扩大暴露范围。真实服务器是否会回显、曾否发生真实泄漏均需验证。只用 300/500 字长度限制不能解决该风险。 |
| 复现步骤 | 1. 准备临时 ready 会议和内存假 key。2. 本机服务用 500 回显该 marker。3. 调用 regenerateSummary，等降级完成。4. 从临时 session.json 与 Markdown 读取 marker。对应 testEchoedSyntheticCredentialIsPersistedAndExported。 |
| 建议修复 | 将用户可见/可持久化错误与调试诊断分离，默认只保留 HTTP 状态、受控分类、经校验的请求 ID 和恢复操作。若需保留服务文案，先移除当前请求的完整 key、Authorization/Bearer 内容、敏感 URL 查询字段，再限制长度；未知响应体不能默认作为可分享内容。日志同样使用安全分类和 private 元数据，不能继续 public 输出原始 Error。集中实现一处安全错误转换，覆盖 rawSnippet、responseMessage、stage partialNotice、Store 和评测工具；对既有 summaryError 内容安排可预览的清理迁移。 |
| 验证方式 | 用假 key 注入 400/401/403/429/500、HTML 错误、200 错误信封、异常 JSON 及不同 key 格式。检查持久化 JSON、UI 提示、Markdown、公开日志均不含秘密；错误仍给出状态/原因分类和可执行恢复步骤。不要仅按 `sk-` 前缀脱敏。 |
| 是否 AI 生成典型问题 | 是：为可诊断性扩散原始回包，缺少保密与分享边界；作者来源不确定。 |
| 本轮实施 | 网络错误体改安全分类，空响应只展示本地产生的诊断，不再持久化原回显；整理失败保留旧纪要 |
| 当前修复位置 | [SummaryEngine.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift) |
| 当前状态与验收 | 新写入与历史诊断已修复 / 合成迁移回归；旧导出和其他备份不自动清除，真实库在运行新版时清理 |

### SEC-005：评测配置把地址和凭据分别补齐

| 字段 | 内容 |
|---|---|
| ID | SEC-005 |
| 类型 | 安全 / AI生成代码 |
| 严重级别 | P1 严重（开发评测工具，非 App 默认使用路径） |
| 置信度 | 高：配置解析与请求构造纯模拟确认 |
| 位置 | [Scripts/llm_judge.py:148](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/Scripts/llm_judge.py#L148)，resolve_judge；[Scripts/llm_judge.py:252](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/Scripts/llm_judge.py#L252)，call_judge |
| 问题描述 | 用户通过 --base-url 或环境变量指定地址但未提供 key 时，resolve_judge 按 model ID 从 WorkBuddy 配置补 key，保留新的 base。没有校验该 key 所属配置的 url 与新地址匹配，之后 call_judge 将该 key 放入新地址的 Bearer。选择另一个评测地址不能自动等同于允许向它发送既有提供商凭据。 |
| 证据 | mock 配置 A=`https://provider-a.invalid/v1` + 假 key A；参数地址 B=`https://provider-b.invalid/v1`。resolve 返回 B+keyA。mock urlopen 验证构造 URL=B/chat/completions，Authorization=Bearer keyA，在发送前抛审查标记。没有读取真实 models.json 或 Keychain，没有实际发送。 |
| 影响 | 开发者换评测网关、模型迁移或拼错地址时，既有提供商 key 被发往另一个服务。触发条件是运行这个脚本并存在上述部分覆盖配置；App 本体不由此自动泄漏。 |
| 复现步骤 | 1. mock workbuddy_models 为 A 的条目。2. 环境清空，args 指定相同 model 和 B 地址但不指定 key。3. 调用 resolve_judge。4. 截获 call_judge 构造请求检查 URL/header。执行本批 judge-probe 即可，禁止用个人真实配置复现。 |
| 建议修复 | 将 endpoint/model/credential/source 视为同一配置对象，按完整对象选择来源，不能逐字段从不同来源补齐。显式 endpoint 覆盖时必须同时显式给该 endpoint 的 key，或选择与规范化 endpoint 严格匹配的配置；否则失败并说明缺少匹配凭据。通用 Keychain fallback 也应绑定 endpoint/提供商，不能覆盖已有不同来源的 key。修正来源文案，使 CLI 参数不被写成环境变量。 |
| 验证方式 | 覆盖完整 env、完整 WorkBuddy、仅 base、仅 key、不同 endpoint 但相同 model、空 key、Keychain fallback。任何未匹配配置应在网络之前失败；完整匹配配置构造预期 URL/header。全部用假凭据和 mock，避免测试读取用户秘密。 |
| 是否 AI 生成典型问题 | 是：方便的“找到就补”逻辑局部正确，合并后的信任关系错误；作者来源不确定。 |
| 本轮实施 | key和base来自完整匹配来源；不混用旧Keychain；dry-run不读凭据 |
| 当前修复位置 | [Scripts/llm_judge.py:148](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/llm_judge.py:148) |
| 当前状态与验收 | 已修复 / mock回归；test_judge_credentials.py：5项通过，未读取真实Key/发送请求 |

### UX-002：待办负责人保存了却没显示

| 字段 | 内容 |
|---|---|
| ID | UX-002 |
| 类型 | UX / Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [WorkbenchView.swift:1910](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WorkbenchView.swift#L1910)，WorkbenchActionDocumentRow；[WorkbenchView.swift:1151](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WorkbenchView.swift#L1151)，actionSection；[MeetingModels.swift:771](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingModels.swift#L771)，ActionItem.owner |
| 问题描述 | 待办行渲染截止、优先级与置信度，完全不消费 owner。若任务标题未重复负责人，用户在待办的唯一展示页无法知道谁负责。 |
| 证据 | 夹具 label=“交付报价单”、owner=“审查甲”；UI 视觉和 AX 均只有任务、截止、优先级、把握。相同会话实际导出带“负责人 审查甲”。源码注释声称负责人跟随行尾，实际没有对应分支。 |
| 影响 | 核心“谁做什么”信息缺失，多人协作需要翻纪要或导出来查，责任归属容易遗漏。 |
| 复现步骤 | 1. 构造 owner 单独存值、label 不带姓名的 ActionItem。2. 打开速览待办。3. 与 JSON/导出对照。 |
| 建议修复 | 在行内稳定位置展示裁剪空白后的 owner，允许长姓名换行，并给读屏明确“负责人：…”；nil/空白不猜人名。把 UI 与导出的 owner 格式化规则收为共享纯函数。 |
| 验证方式 | 有负责人、nil、空白、多人和超长姓名分别检查；视觉/AX/导出一致，姓名不能仅存在 help 悬停文案中，不能被优先级徽标挤出。 |
| 是否 AI 生成典型问题 | 是：模型与导出字段已接通，展示层漏接，注释与实现不符；作者来源不确定。 |
| 本轮实施 | 负责人可见且可换行 |
| 当前修复位置 | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| 当前状态与验收 | 已修复 / UI；upgrade-ui-overview.png和AX明确审查甲 |

### UX-004：缺麦克风权限的后果说明不完整

| 字段 | 内容 |
|---|---|
| ID | UX-004 |
| 类型 | UX |
| 严重级别 | P1 严重 |
| 置信度 | 高（文案与音源契约）；具体设备/系统录音效果需验证 |
| 位置 | [MeetingModels.swift:398](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingModels.swift#L398)，CaptureReadiness.microphoneCaveat；[WhisperPipeline.swift:276](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WhisperPipeline.swift#L276)，MixedRecordingSession.start |
| 问题描述 | 文案说“没有麦克风权限：录音照常，但原文不会区分我方/对方”，把降级解释为仅缺标签。实际采集代码自身明确记录“我方那一路不会有任何样本”，因此不能保证收录本机麦克风发言。 |
| 证据 | 文案在 MeetingModels.swift:401；start 的注释与日志明确 `.microphone` 为 0 帧，却继续启动系统音频采集。没有把真实系统权限关闭来制造丢录。系统声偶然回传麦克风的设备场景不在此作确定性假设。 |
| 影响 | 用户可能认为全文仍完整，只是无归属标签，录完才发现本机发言没有录到；在耳机会议中尤其需要说明可能只有系统声音。 |
| 复现步骤 | 代码确认；实机待验证：在隔离录音流程拒绝麦克风权限、保留系统音频权限，观察提示后录制两路不同测试音，对照输出音源与文字完整性。 |
| 建议修复 | 提示“未获麦克风权限，无法采集本机麦克风；本次可能只录到系统声音，也无法生成完整双路归属”。未询问与已拒绝分别给授权/系统设置路径，若允许继续则明确“仅录系统声音”，录音中和结果中保存降级标记。 |
| 验证方式 | 未询问、拒绝、受限制、正常授权分别验证；不应把麦克风权限不足描述为纯显示问题。拒绝状态继续录音时输出和导出标明录制来源，用户能恢复授权再开新录音。 |
| 是否 AI 生成典型问题 | 是：技术日志知道缺音源，用户提示却缩减成缺标签；作者来源不确定。 |
| 本轮实施 | 缺麦克风说明本机发言可能缺失；未授权不启用麦克风采集 |
| 当前修复位置 | [MeetingModels.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingModels.swift) |
| 当前状态与验收 | 代码已修复 / 需实机；CaptureReadinessTests；真实权限弹窗/音源组合需验证 |

### ARCH-001：编排与副作用集中，隔离不足

| 字段 | 内容 |
|---|---|
| ID | ARCH-001 |
| 类型 | 架构 / 可维护性（附性能风险） |
| 严重级别 | P2 一般，渐进式改进建议 |
| 置信度 | 高（依赖与同步调用事实）；中（对实际卡顿的影响） |
| 位置 | [MeetingStore.swift:21](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L21)、99–104、140、375、1983、2179；`WorkbenchView.swift`；`Package.swift:13` |
| 问题描述 | @MainActor Store 同时处理 UI、录音生命周期、文件复制、全量扫描/JSON 编解码、转写、摘要、设置与密钥访问。只注入了 SessionStorage，录音器、转换器、引擎、UserDefaults/Keychain 仍绑定具体实现，难以确定性测试启动/取消交错和 I/O 故障。 |
| 证据 | Store 2619 行、UI 4343 行；行数只是规模指标，问题依据是职责与依赖。importAudio 在 MainActor 方法中同步调用 copyImportedAudio；后者使用 FileManager.copyItem；reloadSessions 同步全量解码。主线程 I/O 确定存在，尚未测量耗时或内存峰值。 |
| 影响 | 故障注入成本高，状态回归容易漏测；大文件导入、大量历史会话可能阻塞交互（需性能验证）。现有小数据探针不足以证明实际严重卡顿。 |
| 复现步骤 | 结构检查即可确认依赖。性能需验证：以 100/1000 场合成会议和大音频建立隔离夹具，用 Instruments 记录启动与导入的主线程耗时及内存；禁止用真实会议测试破坏性故障。 |
| 建议修复 | 先引入小接口 RecordingSession/AudioPreparing/SessionRepository/SummaryAnalyzing 和明确 OperationState；将磁盘 I/O 移入串行 repository actor，UI 只发布状态与结果；配置采用可注入的 UserDefaults suite。按页面拆出设置、原文、纪要、录音状态视图，保留现有业务逻辑与测试，不要求换框架或数据库。 |
| 验证方式 | 能用假录音器精准控制 start/stop 回调，用失败 repository 验证保存/回滚，测试不依赖系统权限/真实 Keychain。现有测试保持通过；新增批量夹具下主线程不执行长时间文件复制/全量解码，状态切换可追踪。 |
| 是否 AI 生成典型问题 | 不确定；集中式实现也可能来自正常迭代。 |
| 本轮实施 | 拆存储模块、索引查询、更新会议不反复排序；新增数据/编排/网络故障测试 |
| 当前修复位置 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| 当前状态与验收 | 部分改善；首次加载/修补与大音频复制后台执行，录音器可注入；手动reload、转写检查点读改写、音频时长/内容哈希/探针/清洗已后台化，原子事务防止与重命名互相覆盖；手动小文件编辑、删除和故障收尾仍有同步I/O，未完成全面服务分层 |

### BUG-018：字符长度限制不保证合法文件名字节数

| 字段 | 内容 |
|---|---|
| ID | BUG-018 |
| 类型 | Bug |
| 严重级别 | P2 一般 |
| 置信度 | 高 |
| 位置 | [MeetingExport.swift:189](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingExport.swift#L189)，sanitizedTitle；[MeetingStore.swift:451](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/MeetingStore.swift#L451)，导出默认文件名 |
| 问题描述 | `.prefix(60)` 限制 Swift Character 数，不能保证 255 UTF-8 字节。一个组合 emoji/grapheme 可能有很多字节，因此合法输入仍生成无法写入的默认文件名。 |
| 证据 | 标题为 60 个家庭 emoji，fileName 返回 74 个 Character、1514 UTF-8 字节；真实临时文件写入失败。普通中文限制测试通过不足以涵盖 Unicode 边界。 |
| 影响 | 这类标题的导出需要用户手工缩短名称，否则面板或写入拒绝。不是路径遍历，也没有证据证明普通标题导出普遍失败。 |
| 复现步骤 | 1. 标题重复组合 emoji 60 次。2. 用实际 MeetingExporter.fileName 得默认名。3. 统计 utf8.count 并写临时文件。对应 testEmojiTitleExceedsFilesystemByteLimitDespiteCharacterLimit。 |
| 建议修复 | 为日期前缀、分隔符和 `.md` 预留字节预算，按完整 Character 累加 UTF-8 字节直至上限；单个字符超预算时跳过/回退，保留非空安全名。不要用截断原始 UTF-8 Data 的办法破坏字符编码。 |
| 验证方式 | 中文、单 emoji、ZWJ 家庭 emoji、组合音标、仅非法字符与单个超长 grapheme 均覆盖；最终 utf8.count<=255 且可以真实写入。 |
| 是否 AI 生成典型问题 | 是：注释声称处理字节上限，实现却只处理字符数量；作者来源不确定。 |
| 本轮实施 | 按UTF8预算截文件名且不拆Character |
| 当前修复位置 | [MeetingExport.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingExport.swift) |
| 当前状态与验收 | 已修复 / 写盘回归；emoji名称完整导出写盘测试 |

### BUG-019：播放器计时器没有覆盖离开与失败生命周期

| 字段 | 内容 |
|---|---|
| ID | BUG-019 |
| 类型 | Bug / 性能 |
| 严重级别 | P2 一般 |
| 置信度 | 高（对象保留已复现）；UI 销毁/播放失败的具体表现需回归 |
| 位置 | [AudioPlayback.swift:55](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/AudioPlayback.swift#L55)，togglePlayback；102，startTimer；[WorkbenchView.swift:677](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WorkbenchView.swift#L677)，工作区生命周期 |
| 问题描述 | 重复 target Timer 强持有 self；播放器也保存 timer。视图在加载/切会话时停止旧播放器，但工作区整体消失没有 stop。play() 结果没检查就启动 timer，updatePlayback 即使不在播放也不使其失效。 |
| 证据 | 合成 10 秒静音 WAV，实际启动播放后释放所有外部强引用，弱引用仍存在且 isPlaying=true；显式 stop 后对象释放。工作区无 onDisappear 清理。自然播放结束的 delegate 会停 timer，因此不声称所有播放都会永久泄漏。 |
| 影响 | 工作区离开/窗口关闭时，可能仍播放到音频结束且持有音频资源；若 play 失败或异常未走完成回调，重复 timer 缺乏停止保证。完整 App 关窗行为尚未故障注入。 |
| 复现步骤 | 1. 加载隔离静音 WAV 并播放。2. 保留弱引用，释放唯一外部强引用。3. 对象仍存在且播放。4. 显式 stop 后确认释放。对应 testPlaybackTimerRetainsOwnerUntilExplicitStop。 |
| 建议修复 | 在工作区整体离开时明确 stop（不要把切 Tab 当成退出工作区）；计时器改为弱引用闭包或独立生命周期对象，避免仅依赖 deinit 打破自身循环。只有 play() 成功才建 timer，播放失败/解码错误即时清理与报错。 |
| 验证方式 | 播放/暂停/自然结束/失败启动/解码错误、工作区移除与窗口关闭分别检查；不再播放时无重复 timer，明确停止后弱引用释放。切 Tab 仍允许预期的连续回放，切会议不同时播放两个源。 |
| 是否 AI 生成典型问题 | 是：常用 Timer 写法接通正常播放，资源归属与异常收尾遗漏；作者来源不确定。 |
| 本轮实施 | Timer弱引用，离开工作区stop |
| 当前修复位置 | [AudioPlayback.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/AudioPlayback.swift) |
| 当前状态与验收 | 已修复 / 生命周期回归；Timer释放测试；实际有音频回放跨窗口再确认 |

### BUG-021：网关正常返回普通 JSON 却被重复调用

| 字段 | 内容 |
|---|---|
| ID | BUG-021 |
| 类型 | Bug / 性能 |
| 严重级别 | P2 一般 |
| 置信度 | 高：请求次数实测；计费取决于服务商，需验证 |
| 位置 | [SummaryEngine.swift:921](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L921)，requestText 重试；[SummaryEngine.swift:978](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L978)，buffered fallback；[SummaryEngine.swift:1074](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/SummaryEngine.swift#L1074)，SSE 行过滤 |
| 问题描述 | 服务忽略 stream=true，正常返回 application/json + choices.message 时，代码不看 Content-Type，只读 data: 行，因此丢弃已经成功的结果。随后又做两次相同流式请求，最后另做一次 stream=false 请求。协议不支持与暂时性网络失败被混在同一重试路径。 |
| 证据 | 合成网关每次都返回 200、合法 content、finish_reason=stop。一次 Engine.test 触发 4 个生成请求，stream flags=[true,true,true,false]，耗时约 3.79 秒（主要为 1.2+2.4 秒退避），最后才成功。函数名中的 Billable 不代表有真实账单证据；本次网关免费本机夹具。 |
| 影响 | 兼容普通 JSON 的服务浪费请求和等待，可能消耗四份生成额度并引发限流。该实测是一次连通性测试；整场双阶段调用是否达到八次、长会话章节如何放大，本批未实测。 |
| 复现步骤 | 1. 本批服务器使用 buffered 路由，无论 stream 请求值都回 JSON。2. 调用 SummaryEngine.test。3. 统计 requests.jsonl 条目及 stream flags。对应 testIgnoredStreamFlagCausesFourSuccessfulBillableRequests。 |
| 建议修复 | 在第一次响应即按 Content-Type/受支持协议分流。对普通 JSON 的成功回包消费现有 body，复用 buffered 解码函数，避免第二次生成；明确不支持 SSE 的错误只需一次受控 fallback，不应先按网络失败重试三遍。缓存当前 endpoint 的协议能力时允许失效，不能长期误判。429/临时 5xx 与协议兼容分别处理，并保留取消支持。 |
| 验证方式 | 相同夹具应只产生 1 次生成请求；明确 SSE 不支持且无法消费原响应的情形最多一次 fallback。正常 SSE 不多发请求；429、临时 5xx、401、解析错误走各自受控策略。用 mock 请求计数验收，不以真实付费 API 做回归。 |
| 是否 AI 生成典型问题 | 是：兼容 fallback 存在，但此前成功响应未被利用，重试策略与失败种类不匹配；作者来源不确定。 |
| 本轮实施 | stream请求普通JSON成功回包直接解码，复用同一生成结果 |
| 当前修复位置 | [SummaryEngine.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift) |
| 当前状态与验收 | 已修复 / 请求计数；testJSONReplyToStreamRequestUsesOneGeneration：1次请求 |

### DOC-001：README宣称不联云，与可选云端整理不一致

| 字段 | 内容 |
|---|---|
| ID | DOC-001 |
| 类型 | UX / 可维护性 |
| 严重级别 | P2 一般 |
| 置信度 | 高：文档与代码相互矛盾 |
| 位置 | [README.md](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/README.md) |
| 问题描述 | README宣称不联云，与可选云端整理不一致 |
| 证据 | 基线README目标条目声称不联云、不自动上传，但后续模型章节及SummaryEngine支持云端POST逐字稿。 |
| 影响 | 用户对会议正文离开本机的理解可能错误；此处指出声明矛盾，不认定用户已泄漏数据。 |
| 复现步骤 | 1. 比对README目标与总结模型段落。2. 检查makeRequest正文来源。 |
| 建议修复 | 已明确本地保存/云端选择后向所配服务商发送逐字稿；Info.plist数据用途文字同步修正。 |
| 验证方式 | 文档人工核对；本机loopback合成网络测试验证数据请求边界。 |
| 是否 AI 生成典型问题 | 是：局部文档更新未同步承诺，作者来源不确定 |
| 本轮实施 | 明确选择云端后会向配置服务商发送逐字稿 |
| 当前修复位置 | [README.md](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/README.md) |
| 当前状态与验收 | 已修复 / 文档核对；README与Info.plist已对齐 |

### PERF-001：每次读取单条会议都会枚举解码整个数据根

| 字段 | 内容 |
|---|---|
| ID | PERF-001 |
| 类型 | 性能 |
| 严重级别 | P2 一般 |
| 置信度 | 高：合成查询实测 |
| 位置 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| 问题描述 | 每次读取单条会议都会枚举解码整个数据根 |
| 证据 | 基线 SessionStorage.session(with:) 调用 loadSessions().first；本次用不可变目录根与 NSLock 保护的 UUID→目录索引。performance-comparison.log：100 个会议×300 段、查目录末尾会议20次，1.197790秒→0.013592秒，88.12倍。 |
| 影响 | 历史记录增多时，检查点、失败收尾等重复读取放大 I/O。实际整 App 的速度提升未测。 |
| 复现步骤 | 1. 创建100份300段合成清单。2. 同一机器分别运行基线与索引存储查末尾ID20次。3. 比较日志。 |
| 建议修复 | 已建立目录索引，save/load/delete同步维护；不缓存会议正文，仍从单个JSON读最新版本。 |
| 验证方式 | 正式数据测试通过；ReviewPerformanceProbe.swift和performance-comparison.log可复查。启动时全量加载仍在，性能比值只针对该合成查询。 |
| 是否 AI 生成典型问题 | 不确定 |
| 本轮实施 | 单条读取使用UUID目录索引 |
| 当前修复位置 | [SessionStorage.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift) |
| 当前状态与验收 | 已修复 / 合成性能；20次查询1.197790→0.013592秒，只代表指定查询 |

### PERF-002：长逐字稿一次创建全部行

| 字段 | 内容 |
|---|---|
| ID | PERF-002 |
| 类型 | 性能 / 可访问性 |
| 严重级别 | P2 一般 |
| 置信度 | 高： eager构造事实；中：真实卡顿后果 |
| 位置 | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| 问题描述 | 长逐字稿一次创建全部行 |
| 证据 | 基线原文用VStack + ForEach；原1000段AX观察只有滚动区（见VERIFY-UX-001，不能归因于VoiceOver）。升级后LazyVStack，upgrade-ui-long-top-ax.txt可读首屏1–19句，底部证据可读981–1000句。 |
| 影响 | 长文创建和布局成本随内容增长；原读屏观察有工具因素。没有FPS、峰值内存或VoiceOver测量。 |
| 复现步骤 | 1. 启动隔离1000段夹具。2. 打开原文。3. 使用AXScrollToBottom。4. 核对第1000句。 |
| 建议修复 | 已把原文与侧栏改成惰性列表，维持稳定segment.id与时间跳转。 |
| 验证方式 | 合成UI已到首尾，AX内容可读取。需另外用Instruments/VoiceOver验收真实长会。 |
| 是否 AI 生成典型问题 | 不确定 |
| 本轮实施 | 原文/侧栏惰性列表 |
| 当前修复位置 | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| 当前状态与验收 | 代码、AX与本机合成采样改善；1000段首尾AX可达，20.7秒采样无250ms hang记录；未测FPS、峰值内存、VoiceOver或其他规模 |

### PERF-003：子进程日志无界写入、结束后整文件读入

| 字段 | 内容 |
|---|---|
| ID | PERF-003 |
| 类型 | 性能 / 可维护性 |
| 严重级别 | P2 一般 |
| 置信度 | 高 |
| 位置 | [WhisperPipeline.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift) |
| 问题描述 | 子进程日志无界写入、结束后整文件读入 |
| 证据 | 基线LocalProcessRunner将stdout/stderr写临时文件，随后整文件String读取。新增34MiB故障夹具。第一次修复用了URL.resourceValues缓存大小，测试失败；已改为FileManager实时属性，最终testRunawayCLILogIsTerminatedAndDiagnosticIsBounded通过。 |
| 影响 | 异常CLI可长期占磁盘，诊断加载会放大内存与收尾时间。 |
| 复现步骤 | 1. 假CLI向stderr写34MiB并等待。2. runner执行。3. 测量退出和错误字符串长度。 |
| 建议修复 | 已每250ms检查合计32MiB/20分钟，触发TERM后1秒KILL；读取各日志最多2MiB，用户错误文案限长。 |
| 验证方式 | 异常CLI在4秒内结束且诊断小于4000字符。采样阈值可短暂超量，不是严格磁盘配额；持续20分钟真实定时触发未等待验证。 |
| 是否 AI 生成典型问题 | 是：资源边界被遗漏，作者来源不确定 |
| 本轮实施 | 采样日志总量/时间约束，单次诊断读取上限 |
| 当前修复位置 | [WhisperPipeline.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift) |
| 当前状态与验收 | 已修复 / 故障回归；34MiB异常日志任务4秒内结束；采样阈值可短暂超量 |

### SEC-001：审计通过与实际 Mach-O 路径不一致

| 字段 | 内容 |
|---|---|
| ID | SEC-001 |
| 类型 | 安全 / 可维护性 |
| 严重级别 | P2 一般 |
| 置信度 | 高（当前安装产物与审计盲区）；新构建发行包是否同样携带路径需验证 |
| 位置 | [audit_release.sh:32](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/Scripts/audit_release.sh#L32)、57、78；`Scripts/package_app.sh:93` 原样拷贝引擎；安装包 whisper-cli 的 LC_RPATH |
| 问题描述 | 审计只做 strings 特征扫描和 dylib 自身的 otool -D，未检查可执行文件的 LC_RPATH 和所有依赖加载命令。当前安装引擎含开发机绝对 LC_RPATH，运行现有审计仍输出“无私人路径…依赖均为相对路径”。 |
| 证据 | `otool -l <installed whisper-cli>` 的 LC_RPATH 指向 `/Users/<开发者>/Documents/<私人项目>/.../whisper.cpp/build/bin`；当前脚本退出 0。完整取证见 installed-whisper-load-commands.log、installed-release-audit.log。 |
| 影响 | 私人目录信息随二进制传播，分发门禁提供错误保证，依赖可迁移性检查不完整。App 的进程包装器设置 DYLD_LIBRARY_PATH 可补偿当前库定位，所以**没有证据证明 App 内转写因该路径失败，也不是已经验证的远程代码执行漏洞**。 |
| 复现步骤 | 1. 对已安装 whisper-cli 跑 otool -l 并检查 LC_RPATH。2. 跑当前 Scripts/audit_release.sh /Applications/MeetingScribe.app。3. 对比绝对路径与“通过”输出。仅版本号相同不足以断言该产物就是 GitHub 当前提交打包结果。 |
| 建议修复 | 构建引擎时使用 @loader_path/@executable_path/@rpath 的可迁移配置；如用 install_name_tool 调整，必须在重新签名前进行。审计每个 Mach-O 的 otool -L、LC_RPATH 和自身 install name，显式允许系统路径，拒绝用户目录与构建目录；增加移动到临时目录后的 CLI 冒烟测试。 |
| 验证方式 | 用测试 Mach-O 分别植入私人 LC_RPATH、绝对依赖、相对路径、系统路径；前两项必须失败，合法项通过。最终包移到另一目录且不依赖开发机目录，验证 CLI 启动及一段合成音频转写。 |
| 是否 AI 生成典型问题 | 是：检查项看似完整，却没有覆盖声明的二进制元数据；AI 来源不确定。 |
| 本轮实施 | 拷入引擎/库与主程序后清开发机RPATH/依赖，逐个签名并审计；系统/usr/lib/swift保留；保护源运行时 |
| 当前修复位置 | [Scripts/package_app.sh](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/package_app.sh) |
| 当前状态与验收 | 已修复 / 产物验证；otool、每个Mach-O codesign、真实引擎JSON烟测 |

### SEC-006：发行包没有保留内置运行时和模型的第三方许可

| 字段 | 内容 |
|---|---|
| ID | SEC-006 |
| 类型 | 可维护性 / 许可证风险 |
| 严重级别 | P2 一般 |
| 置信度 | 高：打包文件清单事实 |
| 位置 | [Scripts/package_app.sh](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/package_app.sh) |
| 问题描述 | 发行包没有保留内置运行时和模型的第三方许可 |
| 证据 | 基线package_app只复制主程序、Info、引擎/库/模型与图标，make_release_zip仅附首次打开说明。现从whisper.cpp、ggml、openai/whisper官方固定提交获取MIT许可，来源见Packaging/ThirdPartyLicenses/SOURCES.md。 |
| 影响 | 缺少再分发声明；本轮不作法律意见或确切二进制源码来源的认证。 |
| 复现步骤 | 1. 检查基线打包脚本和安装包资源目录。2. 检查新App Resources/Licenses。3. 运行发行审计。 |
| 建议修复 | 已加入本项目及三套第三方许可并设审计缺失门禁；自定义运行时需要其发布者补充其他组件声明。 |
| 验证方式 | 新包审核检查四份非空许可。0.11.5已锁定官方引擎提交和模型SHA，并验证输入/打包文件哈希；正式Developer ID公证仍待完成。 |
| 是否 AI 生成典型问题 | 不确定 |
| 本轮实施 | 打包4份许可并设缺失门禁 |
| 当前修复位置 | [Scripts/package_app.sh](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/package_app.sh) |
| 当前状态与验收 | 许可与官方来源锁定 / 产物验证；0.11.5从官方固定提交构建，签名资源保存来源、构建配置与输入/打包哈希；见追加报告 |

### UX-001：装饰动画被放在真实音源状态位置

| 字段 | 内容 |
|---|---|
| ID | UX-001 |
| 类型 | UX / AI生成代码 |
| 严重级别 | P2 一般；因误判录音完整性的潜在后果，建议与录音状态一同修 |
| 置信度 | 高 |
| 位置 | [WorkbenchView.swift:2772](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WorkbenchView.swift#L2772)，recordingBody；3022，WorkbenchCaptureSourceCard；3058–3081，WorkbenchLevelBars |
| 问题描述 | 麦克风与系统声音各显示一组活动柱，没有音频状态输入；柱高只取当前时间和 sin。静音或某路没样本也会动画。源卡没有把“活动动画”与“真实信号”区分，代码注释却声称表达“有信号在进来”。 |
| 证据 | WorkbenchLevelBars 无 recorder、sample、permission 或 level 参数；barHeight 使用 `date.timeIntervalSinceReferenceDate` 与 sin。两个来源卡都无条件实例化该 View。 |
| 影响 | 用户可能误以为两路都在采集，录完后才发现缺少自己或对方声音。这里只证明反馈没有依据，未证明当前安装 App 的某次实际录音缺路。 |
| 复现步骤 | 1. 在隔离录音测试中令某路无样本或静音。2. 观察该路柱形。3. 预期按现实现继续动画，与真实样本状态无关；本批未实机触发权限或真实录音。 |
| 建议修复 | 显示真实峰值/RMS、最近样本时间、静音与不可用状态；日志中的降级应进入 UI。接入前将动画改为清楚标注的通用“录音进行中”指示，别放在两路信号表的位置。补充 VoiceOver 可读状态与减少动态效果支持。 |
| 验证方式 | 静音、缺权限、设备拔出、只来一路样本、两路正常逐项验证；信号未确认时不能宣称有输入。状态不能只靠动画/颜色表达，读屏应能区分正常、静音、不可用。 |
| 是否 AI 生成典型问题 | 是：视觉完成但没有真实数据连接；不能仅此证明 AI 作者。 |
| 本轮实施 | 展示真实RMS且超时归零，移除sin动画 |
| 当前修复位置 | [AudioTrackRecorder.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/AudioTrackRecorder.swift) |
| 当前状态与验收 | 合成验证 / 需实机；testSharedEpochPreservesFirstPacketOffsetsAndActualLevels；实时设备电平需验证 |

### UX-003：切页静默丢弃未保存草稿

| 字段 | 内容 |
|---|---|
| ID | UX-003 |
| 类型 | UX / Bug |
| 严重级别 | P2 一般 |
| 置信度 | 高（Tab 切换复现）；关窗和其他导航路径需分别回归 |
| 位置 | [WorkbenchView.swift:921](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WorkbenchView.swift#L921)，结果页 switch；[WorkbenchView.swift:1568](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WorkbenchView.swift#L1568)，editingSegmentID；[WorkbenchView.swift:1964](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WorkbenchView.swift#L1964)，行内 draft |
| 问题描述 | 编辑状态与草稿仅在原文子视图保存；切到速览/纪要会销毁该分支，无保存提示或草稿恢复。回到原文是旧正文、只读态。 |
| 证据 | 输入“审查草稿：改为周三交付，尚未保存。”后保存按钮启用；点速览直接离开，回原文仅显示最初的周一文本。没有点击保存或放弃。 |
| 影响 | 用户对照纪要核查原文时丢失未提交的输入，需重新修改；不声称已保存文本丢失。 |
| 复现步骤 | 1. 原文点铅笔并改一段。2. 不保存，切速览。3. 返回原文。4. 再编辑，草稿已不在。 |
| 建议修复 | 将编辑草稿提升到按 sessionID/segmentID 管理的工作区状态，切 Tab 可恢复；或在离开时提供保存/放弃/继续编辑。统一处理切会议、启动任务、关窗，避免只补某颗 Tab 按钮。 |
| 验证方式 | 有变化、无变化、空白无效输入、保存失败分别导航；有变化草稿不静默丢失。确认保存失败后仍留原页和草稿；明确放弃后才清理。 |
| 是否 AI 生成典型问题 | 是：保存 happy path 完整，离开路径的输入保护缺失；作者来源不确定。 |
| 本轮实施 | 编辑段与草稿保存在Store，Tab重建仍可恢复；保存/取消清理 |
| 当前修复位置 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift) |
| 当前状态与验收 | 已修复 / UI；合成草稿周一改周二，切页再返回仍为周二；退出App草稿不保证持久化 |

### UX-005：编辑输入框没有可访问性名称

| 字段 | 内容 |
|---|---|
| ID | UX-005 |
| 类型 | UX / 可访问性 |
| 严重级别 | P2 一般 |
| 置信度 | 高（AX 名称为空）；具体 VoiceOver 朗读流程需实测 |
| 位置 | [WorkbenchView.swift:2110](https://github.com/a916791360/MeetingScribe/blob/bd80e302b88622bb435eb73b47b34b847fb3f86f/WorkbenchView.swift#L2110)，WorkbenchTranscriptDocumentRow.editor |
| 问题描述 | `TextField("", text: $draft, axis: .vertical)` 没有 accessibilityLabel。保存与取消按钮有名称，但聚焦字段本身只提供文本值，不明确这是哪一时间/来源的逐字稿编辑。 |
| 证据 | 合成 UI AX：`64 text field (settable) 审查甲下周一交付报价单。`，没有 Description；相邻保存按钮有 `Description: 保存这一句`。源码无字段标签或共享语义分组。 |
| 影响 | 使用读屏/语音控制时缺少稳定字段名称，多段文本相似或清空字段后难以确认编辑对象。此项不表示键盘保存不可用，Cmd+Return 已验证正常。 |
| 复现步骤 | 1. 在合成原文打开一段编辑。2. 读取 AX 字段名称与值。3. 核对值存在、名称空；直接 VoiceOver 朗读作为后续验收。 |
| 建议修复 | 加明确 accessibilityLabel，如“编辑 00:06 对方的逐字稿”，值仍由 TextField 自身提供；必要时补“Cmd+Return 保存，Escape 取消”的提示。空文本也保留名称，名称不重复整段正文。 |
| 验证方式 | 空/非空值、两段相同正文、不同 speaker 及时间均有唯一可理解的名称；VoiceOver 和语音控制可定位字段，快捷键与焦点顺序保持正常。 |
| 是否 AI 生成典型问题 | 是：视觉编辑器与图标标签完成，输入的语义标签遗漏；作者来源不确定。 |
| 本轮实施 | 编辑框名称含说话人/时间 |
| 当前修复位置 | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| 当前状态与验收 | 已修复 / AX；升级夹具Description含校正逐字稿、我方、00:00；VoiceOver未实测 |

### UX-006：工具栏导入和设置被读成开始录音

| 字段 | 内容 |
|---|---|
| ID | UX-006 |
| 类型 | UX / 可访问性 |
| 严重级别 | P2 一般 |
| 置信度 | 高：原生AX实测 |
| 位置 | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| 问题描述 | 工具栏导入和设置被读成开始录音 |
| 证据 | 升级夹具初次AX：导入和齿轮Description均为开始录音，即使设置有单独label。最终明确三个button标签并给HStack children:.contain，upgrade-ui-toolbar-ax.txt分别为开始录音/导入音频/设置。 |
| 影响 | 依靠控件名称导航的用户难以区分三个入口；实际VoiceOver语音尚未验证。 |
| 复现步骤 | 1. 打开有会议的原生界面。2. 获取工具栏AX。3. 对比可见文本与Description。 |
| 建议修复 | 已给三个动作独立accessibilityLabel，并保持容器子控件独立。 |
| 验证方式 | 最终AX中三个名称正确；仍需VoiceOver键盘朗读验收。 |
| 是否 AI 生成典型问题 | 不确定 |
| 本轮实施 | 工具栏独立名称与子控件 |
| 当前修复位置 | [WorkbenchView.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift) |
| 当前状态与验收 | 已修复 / AX；upgrade-ui-toolbar-ax.txt：开始录音/导入音频/设置 |

## 未计入确认缺陷的观察

VERIFY-UX-001：基线1000段原文AX没有正文子节点，工具遍历/时间因素未排除，未用VoiceOver。升级后惰性列表的首尾AX已有内容，但仍不宣称完成屏幕阅读器验收。见batch-03-review.md与upgrade-ui-observations.md。该项不计入42项问题或P1数量。

## 追加问题详情（0.11.3）

### BUG-026：磁盘读取失败使停止采集被跳过

| 字段 | 内容 |
|---|---|
| ID | BUG-026 |
| 类型 | Bug / 录音生命周期 |
| 严重级别 | P1 严重 |
| 置信度 | 高：代码路径与故障回归 |
| 位置 | [MeetingStore.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:356)，stopRecording |
| 问题描述 | 停止任务先读取session.json，随后才调用录音器stop；读取失败会直接进入失败收尾，将录音器引用置空，未执行显式停止采集。 |
| 证据 | 上轮793032f代码顺序为 `let session = try storage.session(with: sessionID)` → `mixedSession?.stop()`；新故障测试把session.json变为目录，并断言stopCount=1。 |
| 影响 | UI显示停止/失败，但清理设备的必要动作被跳过；实际ScreenCaptureKit是否继续采样需实机验证，不能把模拟器断言当作真实采集结果。 |
| 复现步骤 | 1. 用注入录音器启动隔离会议。2. 将该夹具session.json变为不可读取的目录。3. 点击停止。4. 核对录音器stop计数及保存失败提示。 |
| 建议修复 | 已将停止混合/麦克风采集移到会议文件读取之前；终态失败仍释放任务状态，落盘失败单独提示，保留原始文件。 |
| 验证方式 | AuditClosureTests.testStopReleasesRecordingEvenWhenTerminalStateCannotBeSaved通过；启动期取消和旧回调测试也通过。真实设备掉线/停止超时仍需验证。 |
| 是否 AI 生成典型问题 | 是：成功路径完整，文件异常绕过设备清理；作者来源不确定 |
| 当前状态与验收 | 已修复 / 注入故障回归；实机行为待验 |

### BUG-027：合法同来源跳转丢失模型认证头

| 字段 | 内容 |
|---|---|
| ID | BUG-027 |
| 类型 | Bug / 网络兼容 |
| 严重级别 | P1 严重：要求鉴权且使用合法跳转的服务 |
| 置信度 | 高：真实loopback请求断言 |
| 位置 | [SummaryEngine.swift](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:4)，SummaryRedirectPolicy |
| 问题描述 | 允许同来源跳转后直接使用URLSession构造的新请求，该请求可能已经去掉Authorization，导致第二个请求失去认证。 |
| 证据 | closure-network-before-auth-fix.log：testSameOriginRelativeRedirectKeepsSingleGenerationAndCredentials失败；同来源相对307的请求数、目标路径和正文一致断言通过，认证头断言失败。修复后认证布尔矩阵为[true,true]。 |
| 影响 | 需要认证的模型接口在合法跳转后可能返回401；真实服务的返回行为需验证。本轮不使用真实凭据。 |
| 复现步骤 | 1. 本地合成服务返回307和相对Location。2. 使用假Key调用连接测试。3. 比较初始与目标请求认证头。4. 同时测试跨端口/主机/协议跳转。 |
| 建议修复 | 已在scheme、host、有效port全部相等后，从originalRequest恢复Authorization；跨来源仍直接拒绝，不能无条件补认证头。 |
| 验证方式 | 同来源相对307保持正文与假凭据；301/302/303/307/308跨端口、跨主机和跨协议矩阵拒绝，目标无请求。332项Swift最终全量回归通过。 |
| 是否 AI 生成典型问题 | 是：只验证危险跳转阻断，遗漏允许路径的系统行为；作者来源不确定 |
| 当前状态与验收 | 已修复 / loopback矩阵；真实HTTPS服务矩阵待验 |

## 追加问题详情（0.11.4）

### UX-007：录音尚在准备时界面已宣称采集开始

| 字段 | 内容 |
|---|---|
| ID | UX-007 |
| 类型 | UX / Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高：隔离原生界面实测与状态代码 |
| 位置 | WorkbenchView.swift:2702，WorkbenchProcessingState；MeetingStore.swift:334；窗口副标题和侧边栏状态 |
| 问题描述 | start尚未返回成功，isPreparingRecording=true、isRecording=false，但草稿status=recording驱动红点、录音计时、正在采集和实时写入文案；准备耗时也算入计时。 |
| 证据 | ui-final/initial-ax.txt、preparing-ax.txt和preparing.png记录准备按钮与00:15、录音中、正在采集同时出现；注入录音器start睡30秒，此时尚未确认启动成功。修复前版本为本地e1ddc3f。 |
| 影响 | 用户可能在尚未确认采集成功时开始会议发言；计时与成功启动后的3小时限制不一致。这里确认的是误导反馈，不声称已经实测真实音频丢失。 |
| 复现步骤 | 1. 使用独立bundle ID、合成数据和延迟start录音器。2. 点击开始录音。3. start返回前查看标题、正文、页脚和计时。 |
| 建议修复 | 已显示独立准备页面、等待指示和取消入口；准备时不显示计时/电平/红点/实时写入承诺。recordingStartedAt只在start成功且未取消后设置，计时与上限提示用同一起点。 |
| 验证方式 | preparing-fixed-ax.txt与PNG中全部状态为正在准备录音，且无录音计时或采集承诺；生命周期测试确认准备时起点nil，成功后时间不早于确认启动；真实采集首包时钟另需设备测试。 |
| 是否 AI 生成典型问题 | 是：将草稿状态当成设备成功状态；作者来源不确定 |
| 当前状态与验收 | 已修复 / 原生合成UI、状态回归 |

### UX-008：主动取消录音准备被当成失败

| 字段 | 内容 |
|---|---|
| ID | UX-008 |
| 类型 | UX / Bug |
| 严重级别 | P2 一般 |
| 置信度 | 高：原生操作与取消分支代码 |
| 位置 | MeetingStore.swift:349、1442，录音启动catch和failSession；SafeDiagnostics.swift:6、54；WorkbenchView.swift:602 |
| 问题描述 | 用户点击取消录音准备，统一catch仍执行失败弹窗，提示检查权限、磁盘和模型；重新处理空录音的入口也不适合恢复取消动作。 |
| 证据 | 修复前CUA观察到发生问题弹窗；e1ddc3f的启动catch无取消区分，调用failSession(error.localizedDescription)。修复后cancelled-fixed-ax.txt、cancelled-reopened-ax.txt与PNG记录无弹窗的取消页和恢复的开始录音按钮。 |
| 影响 | 正常取消被解释成系统故障，用户可能无谓修改配置或重试并不存在的录音；不会帮助恢复实际任务。 |
| 复现步骤 | 1. 在延迟启动夹具点击开始录音。2. 在设备确认前取消准备。3. 观察是否弹配置错误及恢复入口。4. 重开检查取消文案。 |
| 建议修复 | 已只把任务取消且未收到设备故障的路径视为用户取消；关闭错误弹窗、持久化固定取消文案、显示中性取消状态与开始录音指引。复用failed存储状态保持旧格式兼容，但界面明确显示取消；故障和保存失败仍告警。 |
| 验证方式 | 原生两次开始/取消和重开均通过；11项AuditClosureTests验证取消后晚返回不进入录音、取消文案持久化、设备故障仍报错、取消保存失败仍显示未能保存。 |
| 是否 AI 生成典型问题 | 是：将所有异常统一等同于用户可见故障；作者来源不确定 |
| 当前状态与验收 | 已修复 / 原生合成UI、故障回归 |

## BUG-029及生命周期补齐详情

BUG-029的完整12字段表、BUG-011取消整理收尾、BUG-028导入快照保护，以及本轮后台事务和性能证据见[0.11.6追加报告](lifecycle/review-and-upgrade.md)。新增问题为P2；已确认P0/P1没有新增计数。
