# MeetingScribe 审查报告 · 第 4 批

日期：2026-10-06。GitHub 基线：`bd80e302b88622bb435eb73b47b34b847fb3f86f`，0.11.1 / build 21。本批聚焦云端请求、密钥与错误信息、本地文件边界、评测工具和发行签名。未修改业务代码，尚非全项目最终报告。

## 结论与问题表

**本批确认了网络目的地、文件操作范围、诊断信息和流式完成判定的边界缺口。** 默认重定向能把会议正文送往配置之外的来源；被修改的会话清单能使删除越出会议数据根；服务端回显的凭据会被写入会议与导出。另有两项协议处理问题和一项开发工具凭据来源错误。

新增 6 项：P1 5 项、P2 1 项，无新增 P0。累计 32 项（P0 1 / P1 23 / P2 8）。这不是线上事故数量：文件逃逸、错误回显和评测凭据问题均有明确触发前提。第一批 BUG-001 的人工校正丢失风险仍应最先处理。

| ID | 类型 | 级别 | 结论 | 证据与前提 |
|---|---|---|---|---|
| SEC-002 | 安全 | P1 | 307 重定向把会议正文送到另一来源 | 实际 URLSession；本机不同端口；本次 Authorization 未转发 |
| SEC-003 | 安全 / Bug | P1（条件性） | 会话路径逃逸造成数据根外删除或写入 | 临时清单 `../`、临时符号链接；需本地清单被改变或异常 |
| SEC-004 | 安全 | P1（条件性） | 未脱敏的服务端错误进入会议文件和导出 | 500 回显假密钥，真实 Store/Exporter；真实服务是否回显未知 |
| SEC-005 | 安全 / AI生成代码 | P1（工具） | 评测脚本混用地址与不同来源的凭据 | 纯模拟 resolver 与构造请求；未读取个人配置、未请求网络 |
| BUG-020 | Bug / AI生成代码 | P1 | SSE 无结束标记的 EOF 被当作完整纪要 | 无 finish_reason、无 DONE、半句文本；返回 partial=false |
| BUG-021 | Bug / 性能 | P2 | 不支持 SSE 的网关触发四次成功生成请求 | 4 次 HTTP 200；stream=true 三次、false 一次；真实计费需验证 |

## 验证范围与证据

- 6 个 Swift 探针使用基线的实际 SummaryEngine、SessionStorage、MeetingStore 和 MeetingExporter，开启 warnings-as-errors，全部捕获预期缺陷。**探针通过表示缺陷复现成功，不表示缺陷已经修复。** 见 [测试源文件](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/ReviewBatch4ReproTests.swift)、[测试日志](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/batch-04-repro.log)。测试已归档移出正式 Tests。
- 网络仅连接 `127.0.0.1` 的两个动态端口，服务器实现见 [batch-04-server.py](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/batch-04-server.py)。会议、API Key 和所有删除目标都是审查夹具自行创建的合成内容。各服务与临时数据目录在测试结束时清理。
- Store 探针仅在内存赋假 key，不调用密钥保存/删除/读取密文入口；初始化沿用产品的钥匙串存在性元数据检查。偏好项在测试后恢复。没有发送真实会议、使用真实 key 或修改安装 App。
- 开发工具检查使用 [batch-04-judge-probe.py](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/batch-04-judge-probe.py)，个人 WorkBuddy 配置和 Keychain 调用被 mock 替换，urlopen 在发送前截获。输出见 [日志](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/batch-04-judge-probe.log)。
- 测试夹具曾出现 Swift 隔离编译问题，以及提示词分流把“不要 JSON”误认作结构化输出；均已修正。这些是审查夹具错误，不列为产品缺陷。当前最终日志对应修正后的六项复现。
- macOS 26.5.2 / Swift 6.3.3 arm64。未验证最低 macOS 15、真实服务商、公网 HTTP 的 ATS 行为、跨主机/跨协议的凭据转发、真实账单或攻击事件。

开发者重复验证：将归档的 ReviewBatch4ReproTests.swift 临时放回本工作树的 Tests/MeetingScribeTests，运行 `swift test --filter ReviewBatch4ReproTests -Xswiftc -warnings-as-errors`，完成后移出；该文件依赖原测试目录位置推导服务脚本路径，不能直接在 docs 目录编译。工具探针可直接运行 `python3 docs/reviews/2026-10-06/batch-04-judge-probe.py`。修复后应反转缺陷断言，按下列验收目标建立正式回归测试，不能继续以现有“复现通过”作为发布标准。

## P1 逐项证据、修复与验收

### SEC-002：云端正文跟随跨来源重定向

| 字段 | 内容 |
|---|---|
| ID | SEC-002 |
| 类型 | 安全 |
| 严重级别 | P1 严重 |
| 置信度 | 高：不同端口来源实测；其他来源组合需验证 |
| 位置 | [SummaryEngine.swift:880](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:880)，makeRequest；[SummaryEngine.swift:1038](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:1038)，performStreamingRequest；[SummaryEngine.swift:1149](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:1149)，performBufferedRequest |
| 问题描述 | 会议原文放入 POST body，通过 URLSession.shared 发出，没有应用级重定向范围控制。配置来源返回 307 后，系统继续把原 body 发往另一来源，应用没有拒绝或要求用户另行配置目的地。来源按 scheme、host、有效 port 判定，不只是主机名。 |
| 证据 | 配置 origin=127.0.0.1:端口A，307 Location=127.0.0.1:端口B。B 实际收到 2 个 POST，速览和纪要的正文都含 REVIEW_SYNTHETIC_MEETING_MARKER。日志 `authorization forwarded=false`：本次系统移除了 Authorization，不能据此声称 key 泄漏，也不能认为正文因此受到保护。 |
| 影响 | 网关配置错误或被篡改时，敏感会议内容流向用户未配置的来源。需要原服务返回重定向；不宣称攻击者能在没有此前提时主动读取会议。 |
| 复现步骤 | 1. 用本批服务建立两个 loopback 端口。2. SummaryEngine.analyze 指向 A 的 redirect 路由，传合成分段。3. A 返回 307 到 B。4. 在 B 请求记录中检查原文 marker。对应 testCrossOrigin307ForwardsSyntheticMeetingAndAuthorization。 |
| 建议修复 | 为生成与模型发现统一使用专用 URLSession 和 redirect delegate。拒绝 scheme/host/有效 port 改变以及 HTTPS 降级；若不需要重定向，直接禁用。允许的同来源跳转也应限制次数。被拒绝时显示可操作提示，让用户自行核对并重新配置地址；不要把已返回的不同目的地自动设为新地址。只检查最终 response.url 太晚，正文可能已经转发。 |
| 验证方式 | 测试 301/302/303/307/308、不同 host/port、HTTPS→HTTP、循环跳转以及取消。被拒绝的目标不得收到任何合成正文或 Authorization；同来源的允许情形正常完成；生成和 /models 共用策略。跨协议、跨主机应在受控环境另测。 |
| 是否 AI 生成典型问题 | 是：请求实现完整，但把敏感请求的信任范围交给系统默认行为；作者来源不确定。 |

### SEC-003：会话清单能改变数据根之外的操作目标

| 字段 | 内容 |
|---|---|
| ID | SEC-003 |
| 类型 | 安全 / Bug |
| 严重级别 | P1 严重（条件性：本地 manifest 被篡改、错误迁移或目录存在异常链接） |
| 置信度 | 高；未发现远程 JSON 导入入口 |
| 位置 | [MeetingStore.swift:2117](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:2117)，loadSession；[MeetingStore.swift:2058](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:2058)，save；[MeetingStore.swift:2064](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:2064)，delete；[MeetingStore.swift:2071](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:2071)，folderURL/sourceURL/inputURL |
| 问题描述 | 读取目录下的 session.json 后，代码信任其 folderName，而不是检查其与实际目录一致。save/delete 直接拼接这个值，既未拒绝 `..` 或路径分隔符，也未限制解析后的目标。符号链接同样能将保存导向根外。音频 preferredFileName 也没有单组件范围校验，应在同一次修复中处理。 |
| 证据 | 将临时合法清单 folderName 改成 `../outside-victim`，从真实 loadSessions 读入后 delete，临时兄弟目录及 sentinel 被删，原会议目录仍在。第二探针建立 meetings/link→兄弟 outside-write，save 把 session.json 写进兄弟目录。所有牺牲目录均由夹具创建。音频字段逃逸本批为静态观察，未另行宣称实际泄漏。 |
| 影响 | 正常 UI 删除会议可能删到 App 用户权限允许访问的其他目录；保存可能写错位置。没有提权、没有远程无需交互攻击证据，也不表示常规自动创建的正常目录会越界。 |
| 复现步骤 | 1. 在临时根创建会议目录与兄弟 sentinel 目录。2. 仅修改该临时 session.json 的 folderName。3. 调用 loadSessions，再 delete。4. 检查兄弟目录消失。符号链接探针单独验证 save。对应 testManifestPathTraversalDeletesOutsideDataRoot / testSymlinkAllowsSessionWriteOutsideDataRoot。 |
| 建议修复 | 建立会抛错的统一路径解析入口，folderName 和音频名必须是非空单一文件名组件，拒绝 `.`, `..`, 分隔符与绝对路径。load 时核对 manifest.folderName 等于所枚举的实际目录名，异常记录隔离并提示，不能静默修成任意路径。解析符号链接后按路径组件核对边界：会议目录必须是 canonical root 的直接子目录，音频必须在已验证的会议目录内；拒绝会话目录符号链接。不要只用字符串 hasPrefix(root.path)，它会误认同前缀兄弟目录。删除前重新校验目标；如把恶意本地并发换链也纳入威胁模型，需使用文件描述符相对操作避免 TOCTOU。 |
| 验证方式 | 在临时目录验收正常会话、清单目录名不一致、`../`、绝对路径、同前缀兄弟目录、目录/文件符号链接、缺失目标。任何非法操作应抛可识别错误，根外 sentinel 不变；正常删除只删除一个会话。异常文件保留给恢复，不能为测试而触碰真实会议根。 |
| 是否 AI 生成典型问题 | 是：happy path 文件拼接正确，持久化输入和删除范围校验遗漏；作者来源不确定。 |

### SEC-004：原始服务端错误污染会议文件与导出

| 字段 | 内容 |
|---|---|
| ID | SEC-004 |
| 类型 | 安全 |
| 严重级别 | P1 严重（条件性：服务或代理错误体回显敏感信息） |
| 置信度 | 高：假密钥回显链路实测；真实服务回显概率未知 |
| 位置 | [SummaryEngine.swift:1212](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:1212)，responseMessage；[SummaryEngine.swift:1200](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:1200)，rawSnippet；[MeetingStore.swift:1338](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:1338)，buildAnalysis；[MeetingExport.swift:35](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingExport.swift:35)，markdown；[MeetingStore.swift:652](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/MeetingStore.swift:652)，模型发现错误日志 |
| 问题描述 | 服务端 error.message/code/type 与原样响应片段只裁剪长度，没有脱敏。非 401/403/404 的错误可经 localizedDescription 放入 fallback.summaryError，再写入 session.json 并作为 notice 导出。另一个发现路径以 privacy.public 记录 String(describing:error)，即使友好文案隐藏 401 信息，也可能仍记录其原始 associated value；该日志分支是静态证据。 |
| 证据 | loopback 服务返回 HTTP 500，error.message 含 `debug Authorization: Bearer REVIEW_SYNTHETIC_CREDENTIAL_NOT_A_REAL_KEY`。使用真实 regenerateSummary 后，重新从磁盘读出的 summaryError 和 MeetingExporter.markdown 均含该假 key。对应测试通过；未把原始运行日志中的真实敏感信息作为材料。 |
| 影响 | 仅用于认证的秘密可能被复制成普通会议内容，随着分享、备份、问题反馈或日志扩大暴露范围。真实服务器是否会回显、曾否发生真实泄漏均需验证。只用 300/500 字长度限制不能解决该风险。 |
| 复现步骤 | 1. 准备临时 ready 会议和内存假 key。2. 本机服务用 500 回显该 marker。3. 调用 regenerateSummary，等降级完成。4. 从临时 session.json 与 Markdown 读取 marker。对应 testEchoedSyntheticCredentialIsPersistedAndExported。 |
| 建议修复 | 将用户可见/可持久化错误与调试诊断分离，默认只保留 HTTP 状态、受控分类、经校验的请求 ID 和恢复操作。若需保留服务文案，先移除当前请求的完整 key、Authorization/Bearer 内容、敏感 URL 查询字段，再限制长度；未知响应体不能默认作为可分享内容。日志同样使用安全分类和 private 元数据，不能继续 public 输出原始 Error。集中实现一处安全错误转换，覆盖 rawSnippet、responseMessage、stage partialNotice、Store 和评测工具；对既有 summaryError 内容安排可预览的清理迁移。 |
| 验证方式 | 用假 key 注入 400/401/403/429/500、HTML 错误、200 错误信封、异常 JSON 及不同 key 格式。检查持久化 JSON、UI 提示、Markdown、公开日志均不含秘密；错误仍给出状态/原因分类和可执行恢复步骤。不要仅按 `sk-` 前缀脱敏。 |
| 是否 AI 生成典型问题 | 是：为可诊断性扩散原始回包，缺少保密与分享边界；作者来源不确定。 |

### SEC-005：评测配置把地址和凭据分别补齐

| 字段 | 内容 |
|---|---|
| ID | SEC-005 |
| 类型 | 安全 / AI生成代码 |
| 严重级别 | P1 严重（开发评测工具，非 App 默认使用路径） |
| 置信度 | 高：配置解析与请求构造纯模拟确认 |
| 位置 | [Scripts/llm_judge.py:148](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/llm_judge.py:148)，resolve_judge；[Scripts/llm_judge.py:252](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/llm_judge.py:252)，call_judge |
| 问题描述 | 用户通过 --base-url 或环境变量指定地址但未提供 key 时，resolve_judge 按 model ID 从 WorkBuddy 配置补 key，保留新的 base。没有校验该 key 所属配置的 url 与新地址匹配，之后 call_judge 将该 key 放入新地址的 Bearer。选择另一个评测地址不能自动等同于允许向它发送既有提供商凭据。 |
| 证据 | mock 配置 A=`https://provider-a.invalid/v1` + 假 key A；参数地址 B=`https://provider-b.invalid/v1`。resolve 返回 B+keyA。mock urlopen 验证构造 URL=B/chat/completions，Authorization=Bearer keyA，在发送前抛审查标记。没有读取真实 models.json 或 Keychain，没有实际发送。 |
| 影响 | 开发者换评测网关、模型迁移或拼错地址时，既有提供商 key 被发往另一个服务。触发条件是运行这个脚本并存在上述部分覆盖配置；App 本体不由此自动泄漏。 |
| 复现步骤 | 1. mock workbuddy_models 为 A 的条目。2. 环境清空，args 指定相同 model 和 B 地址但不指定 key。3. 调用 resolve_judge。4. 截获 call_judge 构造请求检查 URL/header。执行本批 judge-probe 即可，禁止用个人真实配置复现。 |
| 建议修复 | 将 endpoint/model/credential/source 视为同一配置对象，按完整对象选择来源，不能逐字段从不同来源补齐。显式 endpoint 覆盖时必须同时显式给该 endpoint 的 key，或选择与规范化 endpoint 严格匹配的配置；否则失败并说明缺少匹配凭据。通用 Keychain fallback 也应绑定 endpoint/提供商，不能覆盖已有不同来源的 key。修正来源文案，使 CLI 参数不被写成环境变量。 |
| 验证方式 | 覆盖完整 env、完整 WorkBuddy、仅 base、仅 key、不同 endpoint 但相同 model、空 key、Keychain fallback。任何未匹配配置应在网络之前失败；完整匹配配置构造预期 URL/header。全部用假凭据和 mock，避免测试读取用户秘密。 |
| 是否 AI 生成典型问题 | 是：方便的“找到就补”逻辑局部正确，合并后的信任关系错误；作者来源不确定。 |

### BUG-020：流式响应没有结束证据也宣称完成

| 字段 | 内容 |
|---|---|
| ID | BUG-020 |
| 类型 | Bug / AI生成代码 |
| 严重级别 | P1 严重 |
| 置信度 | 高 |
| 位置 | [SummaryEngine.swift:1072](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:1072)，performStreamingRequest；[SummaryEngine.swift:1094](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:1094)，truncated；[SummaryEngine.swift:822](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:822)，SummaryTextResult.isComplete；[SummaryEngine.swift:498](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:498)，partial 判定 |
| 问题描述 | parser 遇 DONE 直接 break，但不保存是否收到终止事件；读取 EOF 时只要 accumulated 非空且 finish_reason 不等于 length，就被 isComplete 接受。代理或服务以合法 HTTP EOF 提前结束 SSE 后，半句纪要会被标作完整。正常网络抛 URLError 的断线不属于这个复现；此处是内容协议没有完成但传输正常结束。 |
| 证据 | /eof 路由只发送一条 content delta，没有终止 choice、finish_reason、DONE。facts 给合法 JSON，minutes 给“合成纪要只输出了半句，后续内容尚未生成”。实际返回保留半句、partialNotice=nil、diagnostics.partial=false、minutesFinishReason=nil，仅 2 次请求。 |
| 影响 | 核心结果看起来已经成功，用户不知道后面的决策或行动可能缺失；直接分享会把不完整内容当正式纪要。无需依赖 JSON 解析失败才能触发。 |
| 复现步骤 | 1. 本批服务器使用 eof 路由。2. Engine.analyze 输入足量合成分段。3. 服务只发送内容后关闭合法响应体。4. 检查 text 与 partial/finishReason。对应 testPrematureSSEEOFIsAcceptedAsCompleteMinutes。 |
| 建议修复 | 显式建模流结束状态：协议成功终止、token 上限、内容过滤/拒绝、未确认 EOF、解析失败。按受支持协议判断完成，不能以非空文字推断成功。至少在无成功 finish_reason 且无协议终止标记时标未完成；保留已收到文本并提示中断。不要把所有不完整都说成 token 上限，也不要自动无上限重生成。兼容某些只给 DONE 或只给 stop 的服务应写明确适配规则和测试。 |
| 验证方式 | 测完整 stop+DONE、仅协议允许的 stop、仅协议允许的 DONE、无终止 EOF、有/无正文、畸形 event、length、content_filter、真实连接异常与取消。未确认 EOF 必须有部分结果状态，UI/复制/导出可见；合法结束不误报。重试失败保留旧可用结果。 |
| 是否 AI 生成典型问题 | 是：针对 length 的局部修复遗漏整体流状态机；已有注释声称检查截断，实际覆盖范围更窄。作者来源不确定。 |

## P2 逐项证据、修复与验收

### BUG-021：网关正常返回普通 JSON 却被重复调用

| 字段 | 内容 |
|---|---|
| ID | BUG-021 |
| 类型 | Bug / 性能 |
| 严重级别 | P2 一般 |
| 置信度 | 高：请求次数实测；计费取决于服务商，需验证 |
| 位置 | [SummaryEngine.swift:921](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:921)，requestText 重试；[SummaryEngine.swift:978](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:978)，buffered fallback；[SummaryEngine.swift:1074](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/SummaryEngine.swift:1074)，SSE 行过滤 |
| 问题描述 | 服务忽略 stream=true，正常返回 application/json + choices.message 时，代码不看 Content-Type，只读 data: 行，因此丢弃已经成功的结果。随后又做两次相同流式请求，最后另做一次 stream=false 请求。协议不支持与暂时性网络失败被混在同一重试路径。 |
| 证据 | 合成网关每次都返回 200、合法 content、finish_reason=stop。一次 Engine.test 触发 4 个生成请求，stream flags=[true,true,true,false]，耗时约 3.79 秒（主要为 1.2+2.4 秒退避），最后才成功。函数名中的 Billable 不代表有真实账单证据；本次网关免费本机夹具。 |
| 影响 | 兼容普通 JSON 的服务浪费请求和等待，可能消耗四份生成额度并引发限流。该实测是一次连通性测试；整场双阶段调用是否达到八次、长会话章节如何放大，本批未实测。 |
| 复现步骤 | 1. 本批服务器使用 buffered 路由，无论 stream 请求值都回 JSON。2. 调用 SummaryEngine.test。3. 统计 requests.jsonl 条目及 stream flags。对应 testIgnoredStreamFlagCausesFourSuccessfulBillableRequests。 |
| 建议修复 | 在第一次响应即按 Content-Type/受支持协议分流。对普通 JSON 的成功回包消费现有 body，复用 buffered 解码函数，避免第二次生成；明确不支持 SSE 的错误只需一次受控 fallback，不应先按网络失败重试三遍。缓存当前 endpoint 的协议能力时允许失效，不能长期误判。429/临时 5xx 与协议兼容分别处理，并保留取消支持。 |
| 验证方式 | 相同夹具应只产生 1 次生成请求；明确 SSE 不支持且无法消费原响应的情形最多一次 fallback。正常 SSE 不多发请求；429、临时 5xx、401、解析错误走各自受控策略。用 mock 请求计数验收，不以真实付费 API 做回归。 |
| 是否 AI 生成典型问题 | 是：兼容 fallback 存在，但此前成功响应未被利用，重试策略与失败种类不匹配；作者来源不确定。 |

## 修复安排与回归清单

建议与前批一起排期，不以本批安全问题替代已有数据保全任务。

1. 先修 BUG-001、SEC-003：保护人工校正、旧结果和根外文件，统一文件边界并让存储失败可见。
2. 紧接 SEC-002、SEC-004、SEC-005：专用网络会话限制目的地、安全错误转换、凭据与地址绑定。SEC-005 改动较小，可独立先合入，不必等待 App 重构。
3. 再修 BUG-020、BUG-021：分离结束状态和协议适配，减少无效重试，补 UI/导出部分结果提示回归。

可在一天内优先完成的独立项：修复 judge 的配置配对；移除 public 原始错误日志并将可导出错误限制为安全分类；增加路径单组件校验与加载目录名一致性检查。符号链接边界、历史数据处理、全入口统一与回归需要另行验收，不能把第一天的校验当作整个文件安全问题完成。

| 验收领域 | 最低验证要求 |
|---|---|
| 数据安全 | 所有异常路径测试仅在临时根；根外 sentinel 不变；旧会议、校正与纪要在失败/取消时保留 |
| 网络目的地 | 拒绝跳转的接收端零请求；允许跳转计数受限；生成、fallback、models 策略一致 |
| 秘密处理 | 假 key 不进入 JSON、分享、公开日志；错误分类与恢复文案仍可用 |
| 评测脚本 | 不匹配 key/endpoint 在网络前失败；mock 覆盖每种部分配置来源 |
| 完整性 | 无终止 EOF 显示部分结果；成功结束正常；协议适配只消费现有成功响应 |
| 请求成本 | JSON 网关单请求成功；网络重试有限；取消立即阻止后续重试 |

## 发行与其他观察：不新增缺陷计数

安装 App 的签名完整性检查通过，但 spctl exit=3/rejected；签名 Authority=PM Studio Signing，flags=0x0，没有 hardened runtime。见 [本机签名检查日志](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/docs/reviews/2026-10-06/batch-04-install-signature.log)。这是安装包观察，不能证明 GitHub Release 的具体文件相同。

仓库 [README.md:155](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/README.md:155) 已明确说明默认自签且未公证，也有完整 [notarize_app.sh](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/notarize_app.sh)。因此不把已披露的分发策略列为新 P1 或隐藏安全漏洞。作为未来正式发行建议：给 [make_release_zip.sh:48](/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/Scripts/make_release_zip.sh:48) 增加显式发行模式，将 Developer ID、runtime、stapler 和 spctl 作为公开稳定发行的门禁；本机自签开发包单独标识。未执行公证脚本、提交 Apple 或绕过系统保护。

已有正确安全措施：后台整理只用内存 key，不主动读取钥匙串密文；whisper 使用 executableURL + arguments 而非 shell 拼接，未发现可据此成立的 shell 命令注入；云端错误体流式读取有大小限制；明确 401/403 的用户提示不展示原始 message。保留这些措施，在边界上补齐即可。

本项目是本机 SwiftUI App，没有 Web 服务、SQL 数据库、cookie 会话。不能机械地把 SQL 注入、CSRF、CORS 或服务端 SSRF 当成已发现问题。任意 http 地址的公网 ATS 行为、依赖许可证完整性及产物供应链固定版本还需要后续验证；没有凭空报出 CVE。

下一批建议聚焦大会议/大量历史记录的性能、MainActor I/O、内存与临时文件增长、测试有效性、构建与维护成本；然后补齐剩余 UX 可访问性验证并汇总最终 Top 10 和修复路线图。
