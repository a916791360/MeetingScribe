# MeetingScribe 0.11.6 生命周期与后台事务追加修复

日期：2026-10-06。以GitHub固定基线 `bd80e302b88622bb435eb73b47b34b847fb3f86f`继续，在0.11.5提交64b7787后实施。累计48项：P0 1 / P1 30 / P2 17。本轮仅新增BUG-029，其他是既有问题的补齐；不重复计数。完整历史表见[总报告](../final-review-and-upgrade.md)。

## 结论与优先级

0.11.6/build26通过350项Swift回归（1项真实云端跳过、0失败）、45项Python测试和7个合成质量case。取消整理保持任务占用直到实际退出；删除跨越取消收尾的整个期间保持独立门禁。导入和后台结果发布保留更新后的人工名称。整理读写、术语准备及删除迁入后台，成功路径不再提前生成无用的整份本地fallback。已安装到/Applications，安装后3场会议、24文件（291314048字节）及全部JSON字段完全一致。Mac锁屏使CUA无法完成启动，原生启动及启动后核对待解锁；安装与数据核对结果见install-final.json。

| 优先级 | 问题 | 本轮实施 | 验收 |
|---|---|---|---|
| P1 | BUG-011：取消整理过早释放任务占用 | cancel只发请求，实际任务收尾后释放；删除等待任务退出且持有独立门禁 | SummaryLifecycleTests取消、重试、删除及失败回归；修复前正确夹具2项5失败 |
| P2 | BUG-028：导入旧草稿覆盖重命名 | copyImportedAudio只对最新manifest原子更新sourceFileName | testImportWithOldDraftSnapshotPreservesConcurrentRename，修复前该项2失败 |
| P2 | BUG-029：后台旧snapshot覆盖新名称UI | 事务递增storageRevision，发布入口拒绝较旧版本 | testLateBackgroundPublicationCannotOverwriteNewerRenameInUI，修复前2失败；溢出/非法mutation保持原件 |
| P2 | ARCH-001：主线程副作用 | 整理读写、删除、术语与失败fallback后台化；请求配置点击时快照 | 34项流水线回归；1千/1万/5万段持久化调度基准 |
| P2 | PERF-002：长文列表 | 补原生1000段首尾AX与20.7秒Instruments采样 | potential-hangs 0条，阈值250ms；未据此宣称60fps或VoiceOver完成 |

## BUG-029 完整问题表

| 字段 | 内容 |
|---|---|
| ID | BUG-029 |
| 类型 | Bug / UX / 数据一致性 |
| 严重级别 | P2 一般 |
| 置信度 | 高 |
| 位置 | MeetingStore.swift：replaceSession（1439行）；SessionStorage.swift：update（101行）；MeetingModels.swift：storageRevision（1166行）。问题来自0.11.5后台事务，修复前提交64b7787的replaceSession未比较版本。 |
| 问题描述 | 后台事务已提交并产生旧名称snapshot；MainActor在await期间把名称更新为新名称；旧snapshot随后发布时直接替换列表。磁盘新名称仍正确，但界面恢复旧名称，重启才重新显示新名称。 |
| 证据 | 修复前replaceSession无条件 `sessions[index] = session`。late-publication-before.log通过真实发布入口复现2个断言失败；修复后revision-and-pipeline-after.log与全量回归通过。 |
| 影响 | 当前界面与磁盘不一致，用户无法确认重命名是否保存；基于旧界面继续操作可能误判记录。本次复现没有音频或正文丢失。 |
| 复现步骤 | 1. 合成会议在后台原子提交，保存返回snapshot。2. Store重命名同一会议并落盘。3. 将第1步snapshot送入replaceSession。4. 比较UI和磁盘名称，修复前UI回旧名称。 |
| 建议修复 | 已新增Optional Int兼容旧JSON；update在同一文件锁内读取最新版本、检查身份与版本不可由mutation修改，然后递增并原子保存。replaceSession只接受不旧于当前版本的snapshot。仍保留同版本同步状态更新。 |
| 验证方式 | late publication测试同时断言UI及磁盘新名；testTransactionRevisionCannotOverflowOrBeChangedByMutation验证Int.max、非法版本及身份修改拒绝且原件保留；旧JSON和完整流水线全量回归。 |
| 是否 AI 生成典型问题 | 不确定；是后台化后常见的发布顺序缺陷，不能据此判定作者。 |

storageRevision用于当前进程内原子事务结果的发布顺序，不提供多进程文件锁或通用冲突合并。save并未整体改成revision事务；手动编辑、草稿创建及故障收尾仍有同步小文件I/O，Store仍集中编排，ARCH-001保持“部分改善”。

## 取消、删除与整理的具体修复

`cancelProcessing`以前取消后立即调用cancelFinishedSummary清空busy/active ID/task；分析器尚未结束，新的整理可重叠、删除可过早移除目录。现在只有原任务实际结束才释放槽位。`isDeletingSessions`在等待原任务、后台删除、列表收尾期间一直有效，录音、导入、重试、reload、编辑、重命名均有守卫。删除失败保留记录并恢复操作。正常录音中的活动会议仍要求先停止，未改变采集授权。

`SummaryRequestContext`在点击时固定settings、内存Key与glossary；不读取钥匙串、不使用真实Key测试。注入SummaryAnalyzer用actor continuation控制实际完成时刻，证明取消后旧纪要保留、重复请求未启动、删除等到收尾。整理成功用repository更新最新manifest，保护期间重命名。MeetingAnalysisWorker执行术语替换及失败fallback，成功路径省去原先提前做的完整fallback分析。

## 验证与性能

| 验证 | 结果 | 证据 |
|---|---|---|
| Swift warnings-as-errors全量 | 350项，1项真实云端跳过，0失败 | full-tests-final.log |
| Python指标/凭据/安装/来源 | 45项通过 | python-tests-final.log |
| 合成质量门禁 | 7个case通过 | quality-final.log |
| 发布版本及流水线 | 34项通过 | revision-and-pipeline-after.log |
| 取消、请求快照、删除失败 | 与全量一致 | SummaryLifecycleTests、summary-pipeline-after.log、delete-pipeline-after.log |
| 真实锁定引擎GPU/CPU | 退出0，JSON解析，599秒offset保持绝对毫秒 | runtime-smoke.py、runtime-smoke-final.log；不测识别准确率 |
| 签名输入来源 | 与0.11.5固定官方输入一致；新包实际签名后哈希匹配provenance | package-final.log、extracted-audit-final.log |
| 发行包 | 0.11.6/build26打包/解压签名与来源审计通过 | zip-final.log、extracted-audit-final.log |
| MainActor调度 | 5万段连续3次保存：同步最大617.176ms，后台7.564ms；平均事务203.244/202.430ms | persistence-benchmark.json、ReviewPersistenceBenchmark.swift |
| 原生1000段列表 | 首尾可达；20.700796秒采样无达到250ms阈值的hang记录 | ui-observations.md、ui-profile.log、ui-hangs.xml |

性能是本机合成测量，调度间隔不是FPS或单次保存耗时；RSS178016 KiB仅为录制后单点，不是峰值或泄漏证明。AX访问参与采样；VoiceOver实际朗读仍待验。

## 失败证据与夹具纠正

- summary-cancel-before-corrected.log是真实取消时序失败；较早summary-cancel-before.log/summary-cancel-after.log的材料不足触发既有历史修补门禁，不能计为产品Bug。
- import-snapshot-before.log中名称覆盖是真Bug；请求快照夹具初次用“=”而不是合法“正确词, 别名”，该语法夹具失败已纠正。
- runtime-signing-parity-before.log错误要求签名后bytes与旧包完全相同。新签名可改变bytes；固定输入SHA相同及新包provenance通过才是正确断言，实际新签名引擎已GPU/CPU再验。
- harness-build-before.log/harness-error-before.log为benchmark未显式丢弃事务返回值导致warnings-as-errors，已用 `_ =`修正。不是App编译故障。

原始Instruments trace/TOC/样本可能含环境与设备标识，仅留本机ignored目录；只交付脱敏TOC及汇总。私有会议和备份不进入Git或交付。

## 安装、回滚与交付

候选通过验收后，先检查真实App空闲、正常⌘Q退出并确认进程结束；新建0700私有备份并逐文件SHA验证，在/Applications同卷暂存候选并验签/来源后替换，保留0.11.5 App用于回滚。安装后所有JSON字段/音频核对见install-final.json。CUA启动尝试因Mac锁屏未能执行，未以shell绕过；startup_verification=pending_mac_locked、data_unchanged_after_launch=null。实际备份为 `/Users/qingmeng/Documents/Codex/MeetingScribe-backups/20261006-142811`，含0.11.5 App。备份路径在该摘要，私有清单仅留备份目录。

回滚时结束录音/处理并正常退出，把当前App另存，再用备份的MeetingScribe-previous.app替换/Applications/MeetingScribe.app并验签。仅回滚App不覆盖数据；恢复会议备份前必须另存升级后的当前数据，避免覆盖新会议。

新稳定交付路径见工作树 `.review-dist/lifecycle-delivery-location.txt`；内含0.11.6 App ZIP、Git源码快照、固定GitHub基线完整补丁、审查证据、SHA清单。补丁应用后与最终提交树一致。此前交付目录保持不可变。仅本地提交，未推送GitHub、未公开Release。本机PM Studio Signing签名；无Developer ID或Apple公证。

## 剩余工作与验收顺序

1. 解锁后启动已安装0.11.6，复核无录音/处理意外启动及全部数据一致；随后验证真实权限首次授予/拒绝、系统声/麦克风/耳机、设备拔插、MOV和双轨绝对偏移、长录音；注入故障不能替代采集实测。
2. VoiceOver完整朗读与焦点；10000段原生交互/峰值内存进一步采样。当前1000段AX/Instruments证据不覆盖全部规模。
3. 另机macOS15、真实HTTPS跨主机/弱网/云端兼容矩阵；使用专用合成资料和测试凭据。
4. Developer ID签名、Apple公证/staple与REQUIRE_NOTARIZATION=1发行门禁；持续依赖漏洞评估。
5. 根据当前大JSON同步编辑基准继续渐进拆Store及小文件保存，保留文件格式与既有功能，不整体重写。
