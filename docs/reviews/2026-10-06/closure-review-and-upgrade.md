# MeetingScribe 0.11.3追加审查与修复验收

日期：2026-10-06。以GitHub基线bd80e30为准，继续上轮793032f的工作；修改在codex/audit-hardening独立工作树。当前为0.11.3/build23。累计**44项：P0 1 / P1 29 / P2 14**，逐项原始证据与全部问题见[完整报告](final-review-and-upgrade.md)。

## 结论与优先级

本轮先闭环历史敏感诊断，再完成录音生命周期与写入异常回归，随后处理启动/导入的主线程文件工作，最后补网络允许与拒绝路径。新增确认缺陷BUG-026、BUG-027已修复。没有替换正在运行的真实应用，也没有读取真实会议或真实API Key进行验证。

| 优先级 | 问题 | 本轮修复 | 验收 |
|---|---|---|---|
| P1 | SEC-004历史错误可能重新进入UI/导出 | 闭集可信诊断；加载时原子清理5类错误字段；保存统一清洗，正文不改 | 任意无特定Key前缀的合成秘密在存储、提示、导出均移除；迁移幂等；写入失败仍能安全读会议并报错 |
| P1 | BUG-005/013/014录音生命周期 | 小型RecordingSession注入；启动取消、旧回调归属与重复故障门禁；原生start回调20秒兜底，stop保持10秒兜底 | 假录音器的准备独占、删除保护、启动期故障、取消后晚返回、旧回调及正常采集中断通过；实际系统定时/设备需验证 |
| P1 | BUG-026停止顺序 | 先停止设备，再读会议清单 | 清单失效时stop仍执行，终态保存失败明确告知 |
| P1 | BUG-027同来源认证 | 仅在完整同来源校验后恢复原始认证头 | 同来源相对跳转和7种拒绝路径通过 |
| P1/P2 | 保存错误静默与导入副本 | 必要进度检查点throws；终态/历史修补失败可见；先完成副本后替换目标 | 缺源导入保留旧文件、成功替换无临时残留、转写期间清单失效不能显示成功 |
| P2 | ARCH-001 | 后台首次读取和历史修补、后台大文件复制、存储完整操作递归锁；保持其他写入在主actor的顺序 | 异步加载期间不允许新建任务，加载后原会议与选择恢复；没有把整Store重写 |

## 验证结果

- Swift最终全量：**332项，1项真实云端E2E跳过，0失败**；warnings-as-errors。见closure-full-tests.log。
- 新增AuditClosureTests 10项和网络矩阵3项；已有全部回归仍通过。
- Python指标28项、凭据模拟5项、安全安装故障5项全部通过；合成质量7个case全部符合预期。
- 0.11.3构建、发行脚本审计、每个运行时Mach-O签名、内置引擎加载与JSON解码、zip解压后审计验证见closure-package/zip/extracted-audit/runtime-smoke日志。
- 新的独立bundle ID原生UI夹具已编译。CUA返回桌面锁定且无法自动解锁，**新增加载/取消界面未完成本轮UI实测**；之前0.11.2的AX与浅深色证据仍只代表上一版。没有绕过桌面锁定。
- 一次全量测试卡在loopback夹具的Foundation waitUntilExit；采样表明子进程已经退出。仅中断自己的测试进程，改为terminationHandler和有界等待后最终全量通过。失败日志和采样保留，不计入最终通过。
- 同来源认证头的新回归先失败后修复；closure-network-before-auth-fix.log留存失败证据。

## 数据与发行边界

历史清理只针对analysis.summaryError、analysis.partialNotice、lastRegenerationError、captureWarning、errorMessage。通过固定诊断替换无法证明可信的字符串，避免正则漏掉无特定前缀的秘密；旧错误详细回显会被舍弃。逐字稿、人工校正、纪要正文保持原样。**不额外备份含秘密的原始错误字段**；若原子写失败，原文件仍保留，显示安全文案并提示尚未清理。旧Markdown、Time Machine和其他副本不会自动消除；正文中用户主动记录的信息也不被删改。

ARCH-001已有渐进改进，但短小JSON保存与手动reload仍可能占用MainActor，不承诺全库规模性能。后台只有首次载入和当前导入副本；录音/导入在首次加载完成前受门禁保护，导入期间禁止编辑/删除活动记录，避免异步旧清单覆盖人工修改。锁用于单个存储实例的完整操作顺序，不声称抵御另一个恶意进程的文件竞态。

运行时与模型复用现有安装包的副本，不宣称升级了whisper.cpp或锁定其精确源码revision；交付清单记录文件哈希用于追踪。第三方许可声明已随包保留，二进制来源与CVE评估仍需要可复现源码与正式发行流程。

真实设备/MOV首包对齐、权限弹窗、VoiceOver、最低macOS15、另一台Apple Silicon机器、真实HTTPS服务和弱网仍需验收。原生start20秒/stop10秒兜底已编译和审查，但本轮没有通过真实系统强制挂起回调来验证计时。当前本机签名无Apple公证，GitHub未推送、未创建Release。

## 修复排期与回归清单

1. 已实施：旧诊断、安全写入、采集清理、任务归属、同来源认证、后台加载/导入。使用合成夹具和最终全量日志逐项验收。
2. 下一批验收：解锁后用隔离UI夹具确认加载反馈、取消准备按钮、键盘焦点、浅深色与错误恢复；随后用专门合成声源验证真实录音及设备故障。
3. 发行验收：退出真实App后再使用保留备份/回滚的安装流程；在macOS15和另一台机器验证，补运行时源码/哈希锁定、依赖漏洞评估和Developer ID公证。
4. 渐进架构：按实际测量迁移剩余同步小文件写入，加入两路独立续跑检查点；不要把保存失败等同于“已持久化”，不要整体重写。

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

