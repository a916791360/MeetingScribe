# MeetingScribe 第五批：性能、维护、发行与边界复查

GitHub固定基线：`bd80e302b88622bb435eb73b47b34b847fb3f86f`。本批新增10项，累计42项（P0 1 / P1 27 / P2 14），另VERIFY-UX-001仍为待验证观察。新版本0.11.2/build22已实施修复；架构分层与真实设备验证见最终报告。

## 结论与问题表

本轮对历史查询、长文渲染、日志资源、极端时间、导入原件、工具栏可访问性、许可声明、云端文档与安全安装进行了补充审查。明确优先处理BUG-022、BUG-023、BUG-024。

| ID | 级别 | 问题 | 实施状态 |
|---|---|---|---|
| PERF-001 | P2 | 每次读取单条会议都会枚举解码整个数据根 | 已修复；验收边界见详情 |
| PERF-002 | P2 | 长逐字稿一次创建全部行 | 已修复；验收边界见详情 |
| PERF-003 | P2 | 子进程日志无界写入、结束后整文件读入 | 已修复；验收边界见详情 |
| BUG-022 | P1 | 时间锚解析与显示可能整数溢出崩溃 | 已修复；验收边界见详情 |
| BUG-023 | P1 | 导入input.wav会与标准化输出重名并替换本机副本 | 已修复；验收边界见详情 |
| UX-006 | P2 | 工具栏导入和设置被读成开始录音 | 已修复；验收边界见详情 |
| SEC-006 | P2 | 发行包没有保留内置运行时和模型的第三方许可 | 已修复；验收边界见详情 |
| DOC-001 | P2 | README宣称不联云，与可选云端整理不一致 | 已修复；验收边界见详情 |
| BUG-025 | P1 | 单路静音会转出虚构文字；固定峰值阈值还会过滤轻声信号 | 已修复数字静音门禁；真实噪声需验证 |
| BUG-024 | P1 | 安装前强制结束App，且未完成复制就移走旧版 | 已修复；验收边界见详情 |

## 问题详情

### PERF-001：每次读取单条会议都会枚举解码整个数据根

| 字段 | 内容 |
|---|---|
| ID | PERF-001 |
| 类型 | 性能 |
| 严重级别 | P2 一般 |
| 置信度 | 高：合成查询实测 |
| 位置 | [SessionStorage.swift:64](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift:64) |
| 问题描述 | 每次读取单条会议都会枚举解码整个数据根 |
| 证据 | 基线 SessionStorage.session(with:) 调用 loadSessions().first；本次用不可变目录根与 NSLock 保护的 UUID→目录索引。performance-comparison.log：100 个会议×300 段、查目录末尾会议20次，1.197790秒→0.013592秒，88.12倍。 |
| 影响 | 历史记录增多时，检查点、失败收尾等重复读取放大 I/O。实际整 App 的速度提升未测。 |
| 复现步骤 | 1. 创建100份300段合成清单。2. 同一机器分别运行基线与索引存储查末尾ID20次。3. 比较日志。 |
| 建议修复 | 已建立目录索引，save/load/delete同步维护；不缓存会议正文，仍从单个JSON读最新版本。 |
| 验证方式 | 正式数据测试通过；ReviewPerformanceProbe.swift和performance-comparison.log可复查。启动时全量加载仍在，性能比值只针对该合成查询。 |
| 是否 AI 生成典型问题 | 不确定 |

### PERF-002：长逐字稿一次创建全部行

| 字段 | 内容 |
|---|---|
| ID | PERF-002 |
| 类型 | 性能 / 可访问性 |
| 严重级别 | P2 一般 |
| 置信度 | 高： eager构造事实；中：真实卡顿后果 |
| 位置 | [WorkbenchView.swift:1563](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:1563) |
| 问题描述 | 长逐字稿一次创建全部行 |
| 证据 | 基线原文用VStack + ForEach；原1000段AX观察只有滚动区（见VERIFY-UX-001，不能归因于VoiceOver）。升级后LazyVStack，upgrade-ui-long-top-ax.txt可读首屏1–19句，底部证据可读981–1000句。 |
| 影响 | 长文创建和布局成本随内容增长；原读屏观察有工具因素。没有FPS、峰值内存或VoiceOver测量。 |
| 复现步骤 | 1. 启动隔离1000段夹具。2. 打开原文。3. 使用AXScrollToBottom。4. 核对第1000句。 |
| 建议修复 | 已把原文与侧栏改成惰性列表，维持稳定segment.id与时间跳转。 |
| 验证方式 | 合成UI已到首尾，AX内容可读取。需另外用Instruments/VoiceOver验收真实长会。 |
| 是否 AI 生成典型问题 | 不确定 |

### PERF-003：子进程日志无界写入、结束后整文件读入

| 字段 | 内容 |
|---|---|
| ID | PERF-003 |
| 类型 | 性能 / 可维护性 |
| 严重级别 | P2 一般 |
| 置信度 | 高 |
| 位置 | [WhisperPipeline.swift:863](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WhisperPipeline.swift:863) |
| 问题描述 | 子进程日志无界写入、结束后整文件读入 |
| 证据 | 基线LocalProcessRunner将stdout/stderr写临时文件，随后整文件String读取。新增34MiB故障夹具。第一次修复用了URL.resourceValues缓存大小，测试失败；已改为FileManager实时属性，最终testRunawayCLILogIsTerminatedAndDiagnosticIsBounded通过。 |
| 影响 | 异常CLI可长期占磁盘，诊断加载会放大内存与收尾时间。 |
| 复现步骤 | 1. 假CLI向stderr写34MiB并等待。2. runner执行。3. 测量退出和错误字符串长度。 |
| 建议修复 | 已每250ms检查合计32MiB/20分钟，触发TERM后1秒KILL；读取各日志最多2MiB，用户错误文案限长。 |
| 验证方式 | 异常CLI在4秒内结束且诊断小于4000字符。采样阈值可短暂超量，不是严格磁盘配额；持续20分钟真实定时触发未等待验证。 |
| 是否 AI 生成典型问题 | 是：资源边界被遗漏，作者来源不确定 |

### BUG-022：时间锚解析与显示可能整数溢出崩溃

| 字段 | 内容 |
|---|---|
| ID | BUG-022 |
| 类型 | Bug |
| 严重级别 | P1 严重（极端时间输入） |
| 置信度 | 高：整数溢出代码路径确定 |
| 位置 | [MeetingModels.swift:1154](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingModels.swift:1154) |
| 问题描述 | 时间锚解析与显示可能整数溢出崩溃 |
| 证据 | 基线OverviewBullet对Int值乘60/3600后转TimeInterval，Int.max分钟会先溢出；clockLabel直接Int(self.rounded())不能处理非有限/超大Double。 |
| 影响 | 损坏记录、极端模型时间字段可使解析或显示trap，阻断打开相应会议。没有认定真实云端已返回这种字段。 |
| 复现步骤 | 1. 构造[Int.max:59]时间锚及infinity/NaN clockLabel。2. 调解析显示。3. 基线静态可确定trap条件；升级用回归测试验证不崩溃。 |
| 建议修复 | 已先转Double再计算，显示时先检查finite并钳制Int转换范围。 |
| 验证方式 | AuditDeliveryTests中极端timestamp回归通过；普通秒、分钟、小时旧测试仍通过。 |
| 是否 AI 生成典型问题 | 是：happy path掩盖数值边界，作者来源不确定 |

### BUG-023：导入input.wav会与标准化输出重名并替换本机副本

| 字段 | 内容 |
|---|---|
| ID | BUG-023 |
| 类型 | Bug / 数据完整性 |
| 严重级别 | P1 严重（保留原件受损） |
| 置信度 | 高：合成afconvert实测 |
| 位置 | [SessionStorage.swift:132](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SessionStorage.swift:132) |
| 问题描述 | 导入input.wav会与标准化输出重名并替换本机副本 |
| 证据 | 基线按用户文件名保存原件，再转换到同目录input.wav。import-filename-collision.log：48kHz双声道合成原件同路径afconvert退出0，文件变成16kHz单声道，SHA256改变。用户选择目录外的原文件未改动。 |
| 影响 | 应用内原音频副本丢失原采样率/声道，回放和后续修订只剩降采样音频；不能宣称所有input.wav导入必失败。 |
| 复现步骤 | 1. 合成48kHz双声道input.wav。2. 导入副本按原名落盘。3. 相同路径转16kHz单声道。4. 对比RIFF头和SHA。 |
| 建议修复 | 已将保留文件名input.wav（大小写归一比较）改存imported-original.wav；禁止session.json覆盖；相同源目标不删除源。 |
| 验证方式 | testImportedInputWAVPreservesOriginalAndManifest验证分离目标、原件字节和清单仍可读。 |
| 是否 AI 生成典型问题 | 是：两个看似合理路径未验证组合，作者来源不确定 |

### UX-006：工具栏导入和设置被读成开始录音

| 字段 | 内容 |
|---|---|
| ID | UX-006 |
| 类型 | UX / 可访问性 |
| 严重级别 | P2 一般 |
| 置信度 | 高：原生AX实测 |
| 位置 | [WorkbenchView.swift:475](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/WorkbenchView.swift:475) |
| 问题描述 | 工具栏导入和设置被读成开始录音 |
| 证据 | 升级夹具初次AX：导入和齿轮Description均为开始录音，即使设置有单独label。最终明确三个button标签并给HStack children:.contain，upgrade-ui-toolbar-ax.txt分别为开始录音/导入音频/设置。 |
| 影响 | 依靠控件名称导航的用户难以区分三个入口；实际VoiceOver语音尚未验证。 |
| 复现步骤 | 1. 打开有会议的原生界面。2. 获取工具栏AX。3. 对比可见文本与Description。 |
| 建议修复 | 已给三个动作独立accessibilityLabel，并保持容器子控件独立。 |
| 验证方式 | 最终AX中三个名称正确；仍需VoiceOver键盘朗读验收。 |
| 是否 AI 生成典型问题 | 不确定 |

### SEC-006：发行包没有保留内置运行时和模型的第三方许可

| 字段 | 内容 |
|---|---|
| ID | SEC-006 |
| 类型 | 可维护性 / 许可证风险 |
| 严重级别 | P2 一般 |
| 置信度 | 高：打包文件清单事实 |
| 位置 | [Scripts/package_app.sh:91](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/package_app.sh:91) |
| 问题描述 | 发行包没有保留内置运行时和模型的第三方许可 |
| 证据 | 基线package_app只复制主程序、Info、引擎/库/模型与图标，make_release_zip仅附首次打开说明。现从whisper.cpp、ggml、openai/whisper官方固定提交获取MIT许可，来源见Packaging/ThirdPartyLicenses/SOURCES.md。 |
| 影响 | 缺少再分发声明；本轮不作法律意见或确切二进制源码来源的认证。 |
| 复现步骤 | 1. 检查基线打包脚本和安装包资源目录。2. 检查新App Resources/Licenses。3. 运行发行审计。 |
| 建议修复 | 已加入本项目及三套第三方许可并设审计缺失门禁；自定义运行时需要其发布者补充其他组件声明。 |
| 验证方式 | 新包审核检查四份非空许可。运行时版本/模型来源仍需正式发行建立可复现锁定。 |
| 是否 AI 生成典型问题 | 不确定 |

### DOC-001：README宣称不联云，与可选云端整理不一致

| 字段 | 内容 |
|---|---|
| ID | DOC-001 |
| 类型 | UX / 可维护性 |
| 严重级别 | P2 一般 |
| 置信度 | 高：文档与代码相互矛盾 |
| 位置 | [README.md:18](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/README.md:18) |
| 问题描述 | README宣称不联云，与可选云端整理不一致 |
| 证据 | 基线README目标条目声称不联云、不自动上传，但后续模型章节及SummaryEngine支持云端POST逐字稿。 |
| 影响 | 用户对会议正文离开本机的理解可能错误；此处指出声明矛盾，不认定用户已泄漏数据。 |
| 复现步骤 | 1. 比对README目标与总结模型段落。2. 检查makeRequest正文来源。 |
| 建议修复 | 已明确本地保存/云端选择后向所配服务商发送逐字稿；Info.plist数据用途文字同步修正。 |
| 验证方式 | 文档人工核对；本机loopback合成网络测试验证数据请求边界。 |
| 是否 AI 生成典型问题 | 是：局部文档更新未同步承诺，作者来源不确定 |

### BUG-024：安装前强制结束App，且未完成复制就移走旧版

| 字段 | 内容 |
|---|---|
| ID | BUG-024 |
| 类型 | Bug / 数据安全 |
| 严重级别 | P1 严重（安装脚本） |
| 置信度 | 高：脚本与隔离故障测试 |
| 位置 | [Scripts/install_app.sh:10](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/install_app.sh:10) |
| 问题描述 | 安装前强制结束App，且未完成复制就移走旧版 |
| 证据 | 基线install_app使用killall，然后移旧App到Trash，再ditto新App。新测试仅临时假应用：运行中、复制失败、签名失败、最终替换失败、成功备份五场景均通过。未对真实录音进程发送终止。 |
| 影响 | 录音/处理可能被安装强制打断；复制失败时原安装路径丢失有效App。真实录音损坏是需验证后果。 |
| 复现步骤 | 1. 阅读killall/先mv后ditto顺序。2. 使用PATH假命令注入上述失败。3. 检查安装路径与旧版版本标记。 |
| 建议修复 | 已拒绝运行中的App（构建前与替换前各检查一次）；目标卷先完整复制验签，再留旧版备份后替换；失败回滚旧版。 |
| 验证方式 | python3 Scripts/tests/test_safe_install.py：5测试通过，原件保存、失败恢复、暂存清理。未运行真实安装。 |
| 是否 AI 生成典型问题 | 是：只实现成功路径，作者来源不确定 |


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
