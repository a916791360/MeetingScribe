# MeetingScribe 0.11.5 追加修复与验收

日期：2026-10-06。GitHub基线为 `bd80e302b88622bb435eb73b47b34b847fb3f86f`，在 `codex/audit-hardening` 独立工作树继续修复。完整问题登记见[汇总报告](../final-review-and-upgrade.md)。累计47项：P0 1 / P1 30 / P2 16；新增BUG-028，其余为已有问题的后续闭环。

## 结论与优先级

0.11.5/build25已本地安装并启动。单路、双路现在保存独立原始检查点，恢复时校验源音频、CLI、模型和分块配置；后台原子保存避免覆盖重命名。人工校正和已有纪要在重试失败期间保持可见，成功后才切换新结果。自定义会议名不会再被转写自动标题覆盖。内置引擎改为官方固定提交构建，模型内容匹配官方LFS SHA256。

| 顺序 | 问题 | 本轮状态 | 验收证据 |
|---|---|---|---|
| 1 | BUG-010 / P1：双路检查点及恢复 | 已修复 / 合成故障回归 | 三个双路恢复测试；已完成分块不重跑，改一条源只重跑该路 |
| 2 | BUG-001 / P0的恢复补齐 | 已修复 / 合成故障回归 | 保留旧人工结果同时独立续跑；单路改变模型使检查点失效 |
| 3 | ARCH-001 / P2：MainActor副作用集中 | 部分改善 | repository事务、后台加载和音频worker；后台测试断言非主线程 |
| 4 | SEC-006 / P2：来源与许可 | 来源锁定、产物验证完成 | runtime-lock、provenance、输入/打包哈希、官方模型、公开漏洞查询 |
| 5 | BUG-028 / P2：手动名称丢失 | 已修复 / 恢复回归 | 手动命名后重试失败、重启恢复至成功，名称保留 |

没有新增已确认的P0/P1分类；前两行是已登记高优先级问题的补齐。合成回归及本机安装完成，不代表全部真实设备与公开发行验收完成。

## BUG-028 逐项问题表

| 字段 | 内容 |
|---|---|
| ID | BUG-028 |
| 类型 | Bug / UX |
| 严重级别 | P2 一般 |
| 置信度 | 高 |
| 位置 | MeetingStore.swift：renameSession（当前801行）、process最终提交（当前1414附近）、MeetingAnalysisBuilder.title（当前2106行）；MeetingModels.swift：titleManuallyEdited（1164行） |
| 问题描述 | 用户自定义会议名称没有持久化来源标记，重新处理成功时无条件生成标题，覆盖手动名称。 |
| 证据 | 修复前renameSession只写title；process成功分支调用 `session.title = MeetingAnalysisBuilder.title(for: session, segments: cleanedSegments)`，builder会按导入文件名或内容重建标题。 |
| 影响 | 用户整理好的会议命名丢失，搜索/识别会议困难；录音和原文不因此删除。 |
| 复现步骤 | 1. 给合成会议改名。2. 重新处理，第二路后续块故障，模拟保存processing后退出。3. 重建Store，恢复至成功。4. 对比最终名称。 |
| 建议修复 | 已添加Optional Bool兼容旧JSON；rename在原子事务中设置true；title builder首先保留手动名称。旧记录无标记时不猜测名称来源。 |
| 验证方式 | testDualTrackRetryRecoveryPreservesOldEditsUntilSuccess、testBackgroundTransactionPreservesConcurrentUnrelatedEdits；最终名称、旧结果保护、检查点均断言。 |
| 是否 AI 生成典型问题 | 不确定；属自动生成与人工编辑优先级不一致，不能由代码判断作者。 |

## 已有问题的具体实施

**恢复与数据保护。** `TranscriptionCheckpoint.swift`新增SingleTrackCheckpoint、DualTrackCheckpoint、每条源的计数及raw segments。内容SHA256验证使用完整源文件而非大小/mtime；同大小同长度文件改变也会失效。环境包含CLI/模型SHA、initialPrompt、分块时长、overlap及格式版本。显式“重新处理”从头创建新的raw检查点，旧正文/纪要保留；进程退出后的自动恢复复用已经提交的分块。取消/失败保留恢复材料；成功清空检查点。没有新版可信检查点的旧记录可加载，但需从头转写，不能安全复用旧版混合计数。

双路总进度现在使用两条实际分块总数之和；601秒与1秒音轨故障时正确显示2/3，而不是2/4。两路时长取最大值；静音门禁保持既有保守规则。提示词和后处理术语设置在每次转写开始取快照。

**后台事务与架构。** `SessionRepository` actor执行流水线JSON读改写；SessionStorage.update在一把NSRecursiveLock内读取最新记录、修改、验证身份、清理诊断和原子保存。rename也使用该事务，避免它反向覆盖后台检查点。手动reload改为后台加载，加载期间拒绝编辑/删除，录音和处理期间拒绝reload。`AudioTranscriptionWorker`执行时长、全文件哈希、探针、清洗并检查取消。手动小文件编辑、删除、草稿创建和故障收尾仍有同步I/O；Store仍承担编排，ARCH-001未宣称全部分层完成。下一步按Instruments测量迁移，而非无必要重写。

**运行时来源。** 官方whisper.cpp v1.9.4 commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`，vendored ggml tree `5b80b54d27a479724e5ee85badf0cbda9eec7f49`。模型仓库ggerganov/whisper.cpp revision `5359861c739e955e79d9a303bcbc70fb988958b1`，small模型SHA `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b`。CMake 3.31.6、Apple clang、arm64/macOS15、非本机CPU专用指令、嵌入Metal。构建脚本验证固定提交及未修改tracked源码；不保证跨工具链位级可复现。

来源资源区分原始输入哈希与重定位/签名后的哈希。子运行时显式签名后生成RuntimeProvenance.plist，再签外层App；避免外层--deep重签改变已记录文件。发行审计检查来源锁、所有运行时哈希、模型官方SHA、路径/签名/许可；每个Mach-O均扫描私人开发路径。公开OSV提交查询和GitHub advisories查询成功，均未返回匹配记录，结果见dependency-check-summary.json；此结果不是无漏洞证明，也不替代持续漏洞跟踪。

## 验证、失败取证与边界

| 验证 | 最终结果 | 证据 |
|---|---|---|
| Swift warnings-as-errors | 343项，1项真实云端测试跳过，0失败 | full-tests-final.log |
| Python指标/凭据/安装/来源 | 45项通过 | python-tests-final.log |
| 合成质量门禁 | 7个case与期望一致 | quality-final.log |
| 单路恢复 | 保留旧编辑、跳过已完成块；改变模型从头转写 | single-resume-tests.log、full-tests-final.log |
| 双路恢复 | 保留旧结果、各自计数；改变单路源不重跑另一路 | dual-resume-after.log、full-tests-final.log |
| 并发事务 | 后台非主线程；名称与计数均保留；禁止改manifest身份 | full-tests-final.log中CheckpointRepositoryTests |
| 真引擎烟测 | GPU/CPU退出0、JSON解析、599秒offset仍为绝对毫秒 | runtime-smoke-final.log；只测运行和时间语义，不测准确率 |
| 平台元数据 | 所有内置CLI/库为arm64，minos15.0 | runtime-platform-check.log；不等同于macOS15实机验收 |
| 候选构建及发行 | 来源/签名/许可/RPATH/依赖门禁通过 | package-final.log、zip-final.log |
| 解压后复验 | 严格验签、来源及实际文件哈希通过 | extracted-audit-final.log |
| 原生合成界面 | 设备准备状态、取消入口和中性反馈；校正⌘Return保存；旧纪要有过期提示 | ui-observations.md；通过CUA操作隔离bundle |
| 安装后数据 | 3场会议，24文件，291314048字节；全部JSON字段及其他文件一致 | install-final.json；不保存真实正文/截图到证据 |

保留了初始失败日志：dual-resume-before.log误将CLI的CPU fallback当成恢复调用，属于夹具错误；修正夹具后dual-resume-before-corrected-fixture.log确实暴露重复完成分块。checkpoint-repository-tests.log中的首个日期比较失败源于ISO8601序列化秒精度，修正为与保存后baseline比较。最终以full-tests-final.log为准，不能把夹具错误计入产品问题。

## 安装、回滚与交付

安装前确认真实App空闲，通过正常⌘Q退出，pgrep确认进程结束。完整数据复制并逐文件哈希验证；候选复制到/Applications临时目录验签及来源校验后替换。启动后所有数据完全一致。备份目录 `/Users/qingmeng/Documents/Codex/MeetingScribe-backups/20261006-135256`，含MeetingScribe-data、MeetingScribe-previous.app（0.11.4）与私有完整性清单。目录权限0700；这些私有文件不进入Git或交付包。

回滚：结束录音/处理并正常退出，保留当前0.11.5 App后，用ditto复制上述MeetingScribe-previous.app回/Applications/MeetingScribe.app，严格验签再打开。仅App回滚不恢复数据目录；如需恢复会议备份，先另存当前数据，避免覆盖升级后的新会议。

新稳定交付目录及SHA在交付目录内delivery-manifest.json记录，路径见工作树 `.review-dist/continuation-delivery-location.txt`。包含0.11.5安装包、源码快照、GitHub基线完整补丁与证据；旧0.11.4/0.11.3交付保持不可变。仅本地提交，未推送GitHub或创建公开Release。本机PM Studio Signing证书签名，未经Developer ID/Apple公证。

## 剩余验收顺序

1. 真实设备：权限首次授权/拒绝、系统声音与耳机、设备拔插、快速开始/停止、MOV与双轨绝对偏移、长录音。现有录音器注入与合成回归不能替代这些实测。
2. VoiceOver完整朗读与键盘焦点、长文性能Instruments测量；本轮不更改系统读屏设置，AX可读不能当作实际读屏通过。
3. macOS15另一台Apple Silicon机器、真实HTTPS/弱网与测试云端兼容矩阵；使用专用合成资料和测试凭据，不使用真实会议或真实Key做故障测试。
4. Developer ID签名、Apple公证及staple，执行REQUIRE_NOTARIZATION=1发行门禁；维护官方引擎/模型更新与漏洞评估。
5. 按测量继续拆Store副作用；保留当前文件格式，避免整体重写。
