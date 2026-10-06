# MeetingScribe 0.11.7 后台人工编辑与数据验收

日期：2026-10-06。GitHub基线 `bd80e302b88622bb435eb73b47b34b847fb3f86f`，继续0.11.6本地提交98df0d2。累计48项（P0 1 / P1 30 / P2 17），本轮补齐ARCH-001、BUG-028/029，不重复登记新ID。

## 结论与问题优先顺序

0.11.6此前因锁屏未能启动的验收已经补齐：原生启动成功、空闲，3场会议24文件（291314048字节）完全匹配升级前备份，见startup-0.11.6.json。0.11.7/build27已安装并原生启动，3场会议24文件与全部JSON字段一致；新私有备份为 `/Users/qingmeng/Documents/Codex/MeetingScribe-backups/20261006-153740`。新版把人工校正和重命名保存移到后台；保存成功才关闭编辑/弹窗，失败保留草稿，保存中拒绝冲突操作与正常退出。故障收尾只更新最新记录的终态字段，避免用旧UI快照覆盖已经保存的新名称。

| 顺序 | 关联问题 | 实施与结论 | 证据 |
|---|---|---|---|
| 1 | BUG-028/029 / P2：终态收尾覆盖尚未发布的新名称 | 原子更新最新记录，仅修改status/error/updatedAt/processingStage，递增版本并发布新结果 | terminal-rename-before.log在旧实现1项1失败；testRecordingFailurePreservesUnpublishedRename修复后通过 |
| 2 | ARCH-001 / P2：人工保存仍阻塞主线程 | rename和逐字稿编辑经过SessionRepository；后者在一把文件锁中校验/修改/写盘 | BackgroundEditingTests，后台线程断言仍通过，合成调度复测 |
| 3 | ARCH-001 / UX：异步保存期间的交互 | 独立isSavingSessions门禁；原文“正在保存”、重命名“正在保存”，失败保留输入/弹窗；⌘Q等待保存 | 原生CUA捕获中间状态及退出提示；continuation任务测试 |
| 4 | 既有后台事务一致性 | 导入转处理中状态、双轨警告使用最新manifest事务 | 完整流水线回归 |

## ARCH-001 本轮12字段补充表

| 字段 | 内容 |
|---|---|
| ID | ARCH-001（既有问题的后续修复） |
| 类型 | 架构 / 性能 / 可维护性 |
| 严重级别 | P2 一般 |
| 置信度 | 高 |
| 位置 | MeetingStore.swift：renameSession、updateTranscriptSegment、persistRecoveryState；SessionRepository.swift：editTranscript；WorkbenchView.swift：重命名弹窗及原文行；MeetingApplicationDelegate.swift：正常退出守卫。 |
| 问题描述 | 原人工校正和重命名在MainActor同步序列化/写入整个会议JSON。记录越长，同步操作阻塞越明显。直接改成await还会引入重复提交、未完成就关闭编辑、正常退出中断保存等新时序，需要一并保护。 |
| 证据 | 0.11.6对应方法直接调用storage.update/storage.save。上轮5万段连续3次同步事务最大MainActor tick间隔617ms，本轮复测671ms，后台约7.6ms；这不是实际编辑UI耗时或FPS测量。 |
| 影响 | 长文保存期间界面不能及时响应；异步改造若没有门禁和持久化确认，用户可能误以为已保存、丢掉输入或重叠启动其他任务。 |
| 复现步骤 | 1. 运行同目录build-lifecycle-harnesses.py，在独立合成根测1千/1万/5万段。2. 比较同步与后台事务的5ms MainActor tick。3. 运行隔离UI，修改原文按⌘Return，保存中再按⌘Q。4. 核对保存状态、退出提示与最终JSON。 |
| 建议修复 | 已把rename及原文校正迁入actor事务；isSavingSessions贯穿等待/写盘/发布，录音、导入、整理、删除、reload及重复编辑有守卫。编辑只有成功才清草稿；重命名只有成功才关闭。正常退出在保存期间返回terminateCancel并提示等待。 |
| 验证方式 | 受控gate验证主线程仍能执行、冲突任务被拒、取消前原件不改、读写失败保草稿、名称并发保留、无改动/空输入不重写文件；原生AX捕获中间状态和⌘Q提示；完整356项回归。 |
| 是否 AI 生成典型问题 | 不确定；属副作用隔离及异步状态管理问题，不能判定作者。 |

## 实现与边界

- `SessionRepository.editTranscript`在storage.update同一锁范围内读取最新记录、校验段ID及文本、同步段数组/派生全文/人工标记/stale并原子保存。无改动或拒绝输入会中止事务，不递增revision或重写JSON。返回Sendable结果，MainActor只负责状态与发布。
- `isSavingSessions`不等于转写任务，不提供取消正在写盘的入口。UI禁止保存中改输入或取消；保存结束才恢复操作。普通失败会显示理由，旧正文和草稿保留。人工保存取消在事务开始前检查；提交已成功时仍如实报告成功，不在提交后把它误说成取消。
- `MeetingApplicationDelegate`只在人工保存期间暂缓正常退出，不修改系统授权，不保证强制结束/掉电/多进程并发。录音与其他退出生命周期的真实设备验收仍保留。
- `persistRecoveryState`仍同步执行小文件终态事务，保证故障时收尾；草稿创建、retry初始保存等仍有同步I/O，Store编排尚未全部拆分。ARCH-001保持部分改善，避免无依据整体重写。
- 版本控制保护本进程内事务发布顺序，不等同多进程文件锁。

## 验证与失败证据

| 验证 | 最终结果 | 文件 |
|---|---|---|
| Swift全量warnings-as-errors | 356项，1项真实云端跳过，0失败 | full-tests-final.log |
| 新增后台编辑 | 6项覆盖门禁/退出、取消、故障、并发名称、无改动、终态收尾 | BackgroundEditingTests.swift；full-tests-final.log |
| Python | 45项通过 | python-tests-final.log |
| 合成质量门禁 | 7个case一致 | quality-final.log |
| 本机引擎GPU/CPU | 退出0、JSON解析、599秒offset保持绝对毫秒 | runtime-smoke-final.log；只验证运行和时间语义 |
| 构建/签名/来源/许可/RPATH | 通过 | package-final.log、zip-final.log |
| ZIP解压复验 | 0.11.7/build27，严格验签与来源通过 | extracted-audit-final.log |
| 合成原生界面 | 原文⌘Return、保存状态、⌘Q拒绝退出、落盘、重命名等待 | ui-observations.md |
| MainActor调度复测 | 5万段连续3次同步671.308ms最大间隔，后台7.557ms | persistence-benchmark.json；不是UI帧率 |
| 安装与启动后的数据 | 见install-final.json；不输出真实正文 | install-final.json、installed-audit-final.log |

保留初始失败：test-isolation-before.log为新增测试的非隔离helper引发Swift6编译诊断，已标MainActor；fixture-selection-before.log错误比较列表首项而不是指定会议ID，修正为按ID后通过。terminal-rename-before.log是恢复旧收尾实现后的真实名称覆盖失败，不能与上述夹具错误混算。完整全量日志是最终判断依据。

## 安装、回滚与交付

确认真实App空闲后正常⌘Q退出，逐文件SHA备份数据及0.11.6 App。候选在/Applications同卷暂存，严格验签和来源审核后替换，失败回滚。随后通过CUA启动并比对全部JSON字段、音频/其他文件；具体备份路径、数量和结果见install-final.json。私有备份权限0700，不进入Git、源码或证据包。

需要回滚时，先结束录音/处理/保存并正常退出，另存当前App，再用本轮备份的MeetingScribe-previous.app（0.11.6）替换并验签。仅App回滚不覆盖会议目录；如需恢复会议备份，先另存当前数据以保留升级后的新会议。

新稳定交付位置见工作树 `.review-dist/editing-delivery-location.txt`，包含App ZIP、Git源码ZIP、固定GitHub基线完整补丁、报告证据及SHA清单。校验完整补丁应用后Git树与最终提交一致；安装程序与候选及ZIP相同。旧交付保持不可变，仅本地提交，未推送或公开Release。自签候选未经Developer ID/Apple公证。

## 剩余验收

真实音源/权限首次授权/设备拔插/MOV与双轨偏移/长录音、VoiceOver实际朗读与焦点、另机macOS15、真实HTTPS与弱网、Developer ID及Apple公证仍待相应条件。此前1000段Instruments采样不覆盖其他规模的帧率/峰值内存。下一轮按实测继续迁移草稿/初始保存及协调层；保留现有文件布局，避免无必要重写。
