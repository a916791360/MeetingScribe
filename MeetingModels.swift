import Foundation

enum CaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone
    case mixed
    case imported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone, .mixed:
            return "会议录音"
        case .imported:
            return "导入音频"
        }
    }

    var shortTitle: String {
        switch self {
        case .microphone, .mixed:
            return "录音"
        case .imported:
            return "音频文件"
        }
    }

    var subtitle: String {
        switch self {
        case .microphone, .mixed:
            return "系统声音与 Mac 麦克风"
        case .imported:
            return "已有音频"
        }
    }

    var selectionLabel: String {
        "\(title) · \(subtitle)"
    }

    var icon: String {
        switch self {
        case .microphone:
            return "mic.fill"
        case .mixed:
            return "wave.3.right.circle.fill"
        case .imported:
            return "square.and.arrow.down.fill"
        }
    }

    static var recordingModes: [CaptureMode] {
        [.microphone, .mixed]
    }
}

enum MeetingStatus: String, Codable, Sendable {
    case recording
    case processing
    case ready
    case failed
}

extension MeetingStatus {
    var title: String {
        switch self {
        case .recording:
            return "录音中"
        case .processing:
            return "转写中"
        case .ready:
            return "已完成"
        case .failed:
            return "失败"
        }
    }

    var icon: String {
        switch self {
        case .recording:
            return "record.circle.fill"
        case .processing:
            return "gearshape.2.fill"
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }
}

// MARK: - 整理模型的连接状态

/// 设置页「获取可用模型」流程的状态。
///
/// **为什么要拆成 enum（而不是继续用一个 `String`）。**
/// 原来这里是一个 `summaryTestStatus: String`，被 **9 种互不相同的语义**复用：
/// 「正在连接」「已获取 N 个」「连接正常 · 未提供列表」「正在测试」「连接正常 · 当前模型可用」
/// 「已选择 X」「API Key 保存失败」「error.localizedDescription」「空」。
/// 后果有两个，都是实测出来的：
/// 1. 界面只能靠 `hasPrefix("连接正常")` 猜颜色——**字符串前缀当类型用**；
/// 2. 失败时把 `error.localizedDescription` 原样贴给用户（多为英文技术串），
///    用户只知道"失败了"，不知道该改什么。
/// 这正是本项目在摘要错误字段上已经学过的教训（§24.8「语义不同的状态必须新开字段」），
/// 只是在设置页重犯了一遍。改成 enum 之后，每个 case 自带文案与色调，编译器保证不漏。
enum SummaryModelTestState: Equatable, Sendable {
    /// 无可展示的信息（刚进入 / 手动填写模型 / 刚切换服务商）。
    case idle
    /// 正在连接服务商、拉取模型列表。
    case connecting
    /// API Key 没能写进钥匙串。
    case keySaveFailed
    /// 连接正常并拿到模型列表；`selected` 为 nil 表示还没选定。
    case loaded(count: Int, selected: String?)
    /// 连接正常，但服务商没有可解析的模型列表 → 需要手动填模型 ID。
    case noList
    /// 正在用当前填写的模型 ID 做一次真实调用。
    case testing(model: String)
    /// 连接正常，当前模型可用。
    case available(model: String)
    /// 用户选定了某个整理模型。
    case selected(model: String)
    /// 失败，带一个**可操作**的原因（不再透出 `localizedDescription`）。
    case failed(SummaryModelFailure)
}

/// 连接失败的原因分类。每一类都必须能回答"下一步做什么"。
///
/// 为什么是四类而不是"一条错误串"：网络不通 / Key 无效 / 地址写错 / 服务商侧出错，
/// 这四种的用户动作**完全不同**（换网络 / 换 Key / 改地址 / 换模型或稍后重试），
/// 混成一句话等于让用户自己猜。原始错误串仍然保留，但只写进日志（`Diagnostics`）。
enum SummaryModelFailure: Equatable, Sendable {
    /// 401 / 403：Key 无效、过期或无权限。
    case auth
    /// 地址不对：格式非法、404、或不是兼容 Chat Completions 的端点。
    case endpoint
    /// 网络不通：超时、连接被拒、代理异常。
    case network
    /// 服务商侧问题：5xx、返回内容无法解析、或指定的模型 ID 不存在。
    case server

    /// 一句话说清"错在哪"。
    var title: String {
        switch self {
        case .auth:
            return "API Key 无效或无权限"
        case .endpoint:
            return "服务商地址不对"
        case .network:
            return "连不上服务商"
        case .server:
            return "服务商拒绝了这次请求"
        }
    }

    /// 一句话说清"下一步做什么"。**必须可执行**，不能只说失败。
    var nextStep: String {
        switch self {
        case .auth:
            return "检查 Key 是否复制完整，或换一个有效 Key 后重新获取模型。"
        case .endpoint:
            return "填入服务商 API 根地址（例如 https://example.com/v1），应用会自动补全 /chat/completions。"
        case .network:
            return "检查网络或代理，然后重新获取模型。"
        case .server:
            return "可能是服务商暂时故障，或模型 ID 不存在；稍后重试，或在设置里换成服务商列出的真实模型 ID。"
        }
    }

    /// 把引擎错误归到四类里。**原始错误串不在这里透出**，由调用方写日志。
    static func classify(_ error: Error) -> SummaryModelFailure {
        if let engineError = error as? SummaryEngineError {
            switch engineError {
            case .missingAPIKey:
                return .auth
            case .invalidEndpoint:
                return .endpoint
            case .networkFailed:
                return .network
            case .requestFailed(let status, _):
                if status == 401 || status == 403 { return .auth }
                if status == 404 { return .endpoint }
                return .server
            case .invalidModelName, .modelUnavailable, .emptyResponse,
                 .budgetExhausted, .invalidModelList, .invalidStructuredResponse:
                return .server
            }
        }
        if error is URLError {
            return .network
        }
        return .server
    }
}

/// 状态色调。**给的是语义档，不是具体色值** —— 具体颜色由视图层从 `AppTheme` 取，
/// 这样深浅色档切换时不用改这里。
enum SummaryModelStateTone: Equatable, Sendable {
    case neutral
    case success
    case danger
}

extension SummaryModelTestState {
    /// 屏幕上显示的文案。`.idle` 是空串（不显示）。
    var message: String {
        switch self {
        case .idle:
            return ""
        case .connecting:
            return "正在连接服务商…"
        case .keySaveFailed:
            return "API Key 保存失败。请重试保存后再获取模型。"
        case .loaded(let count, let selected):
            return selected == nil
                ? "已获取 \(count) 个模型，请选择一个"
                : "连接正常 · 已获取 \(count) 个模型"
        case .noList:
            return "连接正常 · 服务商未提供模型列表，请手动填写模型 ID"
        case .testing(let model):
            return "正在测试 \(model)…"
        case .available(let model):
            return "连接正常 · \(model) 可用"
        case .selected(let model):
            return "已选择 \(model) · 会后整理将使用它"
        case .failed(let reason):
            return "\(reason.title)：\(reason.nextStep)"
        }
    }

    /// 有没有话要说。`.idle` 之外都要显示。
    var showsMessage: Bool {
        self != .idle
    }

    /// 是否正在忙（用于禁用按钮 / 转圈）。
    var isBusy: Bool {
        switch self {
        case .connecting, .testing:
            return true
        case .idle, .keySaveFailed, .loaded, .noList, .available, .selected, .failed:
            return false
        }
    }

    var tone: SummaryModelStateTone {
        switch self {
        case .idle, .connecting, .noList, .testing:
            return .neutral
        case .loaded, .available, .selected:
            return .success
        case .keySaveFailed, .failed:
            return .danger
        }
    }
}

/// 主窗口用的结论：**「重新整理」这一下会不会真的干活。**
///
/// 与设置页那次连接测试无关 —— 它只回答"现在点重新整理，会发生什么"。
/// 为什么需要它：设置页那次连接的结论只活在设置面板里，主窗口的「重新整理」
/// 看起来永远可用（`canRegenerateSummaryNow` 只判本地配置，不判模型可达性），
/// 用户点了才发现没配好。这里把结论抬到主窗口常驻。
enum SummaryModelReadiness: Equatable, Sendable {
    /// 本地保守整理，永远可用。
    case localRules
    /// 云端 + 有 Key + 有模型名。可用（但**未做真实可达性验证**）。
    case configured(provider: String, model: String)
    /// 云端，但内存里没有 Key（启动时故意不读钥匙串密文）。
    case needsKey(provider: String)
    /// 云端，但没选 / 没填模型。
    case needsModel(provider: String)

    var isReady: Bool {
        switch self {
        case .localRules, .configured:
            return true
        case .needsKey, .needsModel:
            return false
        }
    }

    /// 一行状态描述（可用时用中性文案，不可用时说清缺什么）。
    var summary: String {
        switch self {
        case .localRules:
            return "整理模型：本地保守整理（不需要网络）"
        case .configured(let provider, let model):
            return "整理模型：\(provider) · \(model)"
        case .needsKey(let provider):
            return "整理模型：\(provider) 还没有可用的 API Key"
        case .needsModel(let provider):
            return "整理模型：\(provider) 还没有选择模型"
        }
    }

    /// 需要用户动作时给出的提示（可用时为 nil，主窗口因此不显示任何东西）。
    var attentionMessage: String? {
        switch self {
        case .localRules, .configured:
            return nil
        case .needsKey:
            return "自动整理不会直接读钥匙串（避免弹系统密码框）。打开设置保存一次 Key，或切换成本地保守整理。"
        case .needsModel:
            return "打开设置选择或填写一个模型，就能生成完整纪要。"
        }
    }

    /// 提示条上那颗按钮的标题。
    var actionTitle: String {
        switch self {
        case .localRules, .configured:
            return "打开设置"
        case .needsKey:
            return "打开设置授权模型"
        case .needsModel:
            return "打开设置选择模型"
        }
    }
}

// MARK: - 录音权限（只 preflight，不请求）

/// 系统音频（屏幕录制）权限。
///
/// **macOS 的特殊行为必须讲给用户**：这个权限**刚授权后不会补发给正在运行的进程**，
/// 必须完全退出重开。这不是 App 的 bug，所以文案要把它说成一句可操作的说明，
/// 而不是一句"失败了"。
enum ScreenCapturePermission: Equatable, Sendable {
    case granted
    case denied

    var isGranted: Bool { self == .granted }

    var label: String {
        switch self {
        case .granted: return "已授权"
        case .denied: return "未授权"
        }
    }
}

/// 麦克风权限。
///
/// 三种状态要分开：`denied` 不会再弹系统窗口（只能去系统设置改），
/// `notDetermined` 在录音开始时会弹一次 —— 处置完全不同。
enum MicrophonePermission: Equatable, Sendable {
    case granted
    /// 曾被拒绝，或受系统限制。
    case denied
    /// 从未询问过。
    case notDetermined

    var isGranted: Bool { self == .granted }

    var label: String {
        switch self {
        case .granted: return "已授权"
        case .denied: return "未授权"
        case .notDetermined: return "尚未询问"
        }
    }
}

/// 开始录音**之前**就能看清的两道门。
///
/// 为什么要有这个东西：原来两道权限的检查都发生在**用户点了录音之后**
/// （`MixedRecordingSession.start()` 里），而且两道门塌成一句合并文案、
/// 麦克风那一道**失败不抛**（只写日志）—— 界面上完全看不见。
/// 结果是用户录完半小时才发现"原文没有我方/对方"，而原因早就存在于一个他不知道的权限里。
enum CaptureReadiness: Equatable, Sendable {
    case ready
    /// 缺系统音频权限 —— **录不了**，必须先授权。
    case missingSystemAudio(microphone: MicrophonePermission)
    /// 系统音频 OK、缺麦克风 —— **录得了**，但无法采集本机麦克风声音。
    case missingMicrophoneOnly

    var canStartRecording: Bool {
        switch self {
        case .ready, .missingMicrophoneOnly:
            return true
        case .missingSystemAudio:
            return false
        }
    }

    /// 拦住录音时给一句**可执行**的说明（不拦时为 nil）。
    var blockingMessage: String? {
        switch self {
        case .ready, .missingMicrophoneOnly:
            return nil
        case .missingSystemAudio:
            return "还没有获得「屏幕与系统音频录制」权限，现在录音采不到对方的声音。请在系统设置里允许 MeetingScribe，然后完全退出并重新打开这个应用（系统不会把刚给的权限补发给正在运行的进程）。"
        }
    }

    /// 不拦录音、但必须说清后果的一条旁注（都齐了时为 nil）。
    var microphoneCaveat: String? {
        switch self {
        case .missingSystemAudio, .missingMicrophoneOnly:
            return "没有麦克风权限：本次只录系统声音，本机麦克风发言可能缺失，也无法区分「我方 / 对方」。请在系统设置中允许麦克风后重试。"
        case .ready:
            return nil
        }
    }
}

enum PriorityLevel: String, Codable, CaseIterable, Sendable {
    case p1
    case p2
    case p3

    var label: String {
        switch self {
        case .p1:
            return "P1"
        case .p2:
            return "P2"
        case .p3:
            return "P3"
        }
    }

    var tint: String {
        switch self {
        case .p1:
            return "red"
        case .p2:
            return "orange"
        case .p3:
            return "secondary"
        }
    }

    var friendlyLabel: String {
        switch self {
        case .p1:
            return "高"
        case .p2:
            return "中"
        case .p3:
            return "低"
        }
    }
}

enum SummaryModelProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case localRules
    case ollama
    case deepSeek
    case kimi
    case zhipu
    case miniMax
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localRules:
            return "本地保守整理"
        case .ollama:
            return "Ollama（本机）"
        case .deepSeek:
            return "DeepSeek"
        case .kimi:
            return "Kimi"
        case .zhipu:
            return "智谱"
        case .miniMax:
            return "MiniMax"
        case .custom:
            return "自定义兼容接口"
        }
    }

    var subtitle: String {
        switch self {
        case .localRules:
            return "不使用总结模型，只保留明确决策和待办"
        case .ollama:
            return "通过本机 Ollama 运行总结模型"
        case .deepSeek, .kimi, .zhipu, .miniMax:
            return "调用对应厂商的 OpenAI 兼容接口"
        case .custom:
            return "填写服务商地址，测试后选择模型"
        }
    }

    var defaultModelName: String {
        switch self {
        case .localRules:
            return "本地保守整理"
        case .ollama:
            return "qwen2.5:7b"
        case .deepSeek:
            return "deepseek-chat"
        case .kimi:
            return "moonshot-v1-32k"
        case .zhipu:
            return "glm-4-flash"
        case .miniMax:
            return "MiniMax-Text-01"
        case .custom:
            return ""
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .localRules:
            return ""
        case .ollama:
            return "http://127.0.0.1:11434/v1/chat/completions"
        case .deepSeek:
            return "https://api.deepseek.com/chat/completions"
        case .kimi:
            return "https://api.moonshot.cn/v1/chat/completions"
        case .zhipu:
            return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        case .miniMax:
            return "https://api.minimaxi.com/v1/text/chatcompletion_v2"
        case .custom:
            return ""
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .localRules, .ollama:
            return false
        case .deepSeek, .kimi, .zhipu, .miniMax, .custom:
            return true
        }
    }

    var isLocal: Bool {
        self == .localRules || self == .ollama
    }

    var icon: String {
        switch self {
        case .localRules:
            return "checkmark.seal"
        case .ollama:
            return "desktopcomputer"
        case .deepSeek, .kimi, .zhipu:
            return "cloud"
        case .miniMax:
            return "waveform"
        case .custom:
            return "slider.horizontal.3"
        }
    }
}

struct SummaryModelSettings: Codable, Hashable, Sendable {
    var provider: SummaryModelProvider
    var modelName: String
    var endpoint: String

    static let `default` = SummaryModelSettings(
        provider: .localRules,
        modelName: SummaryModelProvider.localRules.defaultModelName,
        endpoint: SummaryModelProvider.localRules.defaultEndpoint
    )

    var displayName: String {
        switch provider {
        case .localRules:
            return provider.title
        default:
            let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? provider.title : "\(provider.title) · \(name)"
        }
    }
}

/// 一段发言是**谁**说的（P2-2a 双声道）。
///
/// ⚠️ 取值来自**音轨来源**，不是声纹识别：`local` 是麦克风那一路（本机用户），
/// `remote` 是系统声音那一路（会议软件里传出来的对方）。所以这个标签**只在双声道
/// 录音里存在** —— 导入的音频、单路录音、以及升级前的全部老会话都是 `nil`，
/// 界面与整理 prompt 遇到 `nil` 时什么都不显示，**绝不替它猜一个说话人**：
/// 猜错的说话人是本项目最怕的那类"看不见的数据损坏"（读起来完全自然，永远没人发现）。
enum TranscriptSpeaker: String, Codable, Hashable, Sendable {
    /// 我方：麦克风那一路。
    case local
    /// 对方：系统声音那一路。
    case remote

    /// 界面上显示的名字。**同一个词只在这里写一次**，逐字稿页与整理素材共用。
    var displayName: String {
        switch self {
        case .local: return "我方"
        case .remote: return "对方"
        }
    }

    /// 给整理模型看的**说话人约定**。拆成两块，因为它们的**适用条件不一样**。
    ///
    /// 这一段是 P2-2a 的**目的本身**：`actionsWithOwnerRatio` 长期卡在 16%，
    /// 材料侧天花板只有 22.9%，而这 22.9% 里相当一部分是"你负责"这类**跨方指代** ——
    /// 双声道把它变得可判定之后，必须同时告诉模型"可以判定了"，否则它还是照旧写"会上讨论了"。
    ///
    /// - `materialMarkerExplanation`：解释 `[我方]`/`[对方]` 这两个**标记**本身。
    ///   只有当源材料里真的出现这两个标记时才给 —— 对一份没有说话人的材料解释
    ///   "[我方] 表示什么"，是往 prompt 里塞假信息。
    /// - `speakerAttributionDirective`：要求**写清归属**。只要这场会议有说话人信息就该给，
    ///   与"这份材料里还有没有标记"无关：长会综合那一步拿到的是章节摘要，早就没有标记了，
    ///   但结论与待办照样要写归属。
    ///
    /// ⚠️ **2026-09-17 修正**（此前这里只有一整块 `materialLegend`，且只被拼进**分章**那一步）：
    /// 分章是**中间产物**，真正产出速览与纪要的是它后面那一步，而那一步从来没收到过
    /// "写清归属"这条指令。当时文档给的理由是"分章是唯一看得见原文的一步" ——
    /// 这对长会成立，对 ≤2.4 万字的**直接路径**（大多数会议）不成立：那一步拿到的
    /// **就是**带 `[我方]/[对方]` 的原文。结果是"能不能写出归属"完全靠模型自觉，
    /// 而这正是这一整段话想解决的事。
    static let materialMarkerExplanation = """
    原文里的 [我方] 指本机麦克风里的说话人，[对方] 指会议软件里传来的声音；没有这两个标记的行就是没分出来，别猜。
    """

    /// 归属要求。措辞**刻意与拆分前逐字一致** —— 分章那一步的 prompt 已经跑在生产上，
    /// 不借着"拆一下"顺手改它的字。
    static let speakerAttributionDirective = """
    凡原文标了说话人：结论、决策与待办都要写清**归属** —— 谁提的、谁答应的、谁负责，不要混成"会上讨论了"。
    待办要能从原文看出归属就写进"谁来做"（写"我方"或"对方"），看不出来就留空，不要编。
    """

    /// 两块合起来的完整约定（分章那一步用 —— 它既看得见标记，也需要归属）。
    ///
    /// **不是第三份文案**：它是上面两块按行拼起来的。`TranscriptSpeakerTests` 钉住这条等式，
    /// 免得将来只改其中一块、这里悄悄留下旧话。
    static var materialLegend: String {
        materialMarkerExplanation + "\n" + speakerAttributionDirective
    }
}

/// 双声道两路的**文件命名约定**（P2-2a）。
///
/// ## 为什么要单独抽出来
///
/// 这里有两组名字、四个文件，用途完全不同 —— 混起来会**静默**出事：
///
/// - `capture*`：录音时 `AudioTrackRecorder` 直接落的**原始**文件（`.caf`，无长度上限）。
/// - `normalized*`：归一化之后真正交给 whisper 的 16 kHz 单声道 wav。
///
/// 两组名字**必须不同**：归一化是"读 `capture`、写 `normalized`"，同名会让
/// `afconvert` 的输入输出撞在同一个文件上（要么原地截断，要么报错，两种都不是你想要的）。
/// 这条用单测钉住（`DualTrackPathsTests`）。
///
/// `normalized*` 还是**存进会话记录、事后按名字找回来**用的那份
/// （`MeetingStore.resolvedDualTracks(for:)`），所以它也**只能有这一处定义**。
enum DualTrackPaths {
    /// 我方（麦克风）那一路的原始录音文件名。
    static let localCaptureName = "local.caf"
    /// 对方（系统声）那一路的原始录音文件名。
    static let remoteCaptureName = "remote.caf"
    /// 归一化后的文件名；同时也是写进会话记录、事后找回来的名字。
    static let localNormalizedName = "local.wav"
    static let remoteNormalizedName = "remote.wav"

    /// 录音开始时，两路原始文件的落盘位置。
    static func captureURLs(in folder: URL) -> (local: URL, remote: URL) {
        (
            folder.appendingPathComponent(localCaptureName),
            folder.appendingPathComponent(remoteCaptureName)
        )
    }
}

struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var confidence: Double
    /// 这一段**被人手改过**（P1-4 的就地编辑）。
    ///
    /// 为什么必须记到**段**而不是只记到会话：`TranscriptCleaner.applyingTerminology`
    /// 在每次「重新整理纪要」时都会跑一遍，而用户手改的那句正是**已经被确认过的真相**。
    /// 只记到会话级的话，改过的段还会被术语表再替换一次 —— 用户改掉「课考」，
    /// 术语表可能又把它换回去，**改了半天白改，而且没有任何报错**。
    ///
    /// Optional + 合成 `Codable`：老会话没有这个键照样能解出来（nil），
    /// 也不会往没有编辑过的段上写一个多余的 `null`。
    var manuallyEditedAt: Date?

    /// 这一段的说话人（P2-2a）。**只有双声道录音才有值**，见 `TranscriptSpeaker`。
    ///
    /// 同样必须 Optional：升级前的老会话里没有这个键，非 Optional 会让**所有老会话
    /// 都读不出来**（Swift 合成的 `Decodable` 不理会属性默认值）。
    var speaker: TranscriptSpeaker?

    var timeLabel: String {
        "\(start.clockLabel) - \(end.clockLabel)"
    }

    /// 送进整理模型的**唯一**行格式。
    ///
    /// 为什么必须钉在模型上、而不是留在 `SummaryEngine` 里：转写正文与分章**两处**
    /// 都要拼这一行。两处各写一遍，就会出现"正文带着说话人、分章没带"这种
    /// 静默不一致（本项目铁律：同一判据出现在第 2 处就必须抽函数 + 补单测）。
    ///
    /// 说话人缺失时**整段前缀都不出现**，不写 `[不明]` 之类的占位 —— 那会变成
    /// 一条模型必须解释的假信息。
    var materialLine: String {
        let prefix = speaker.map { "[\($0.displayName)] " } ?? ""
        return "[\(start.oneDecimalSeconds)] \(prefix)\(text)"
    }
}

/// 播放头落在哪一段（原文页的「当前句」高亮用它）。
///
/// **判据是「最后一段的起点 ≤ t」，不是「t 落在 start...end 之间」。**
/// whisper 在有停顿时不产段，段与段之间是**真实的空隙**（几秒很常见）。
/// 用区间判断的话，播放到空隙里就会返回 nil —— 界面上表现为「高亮忽然消失一下
/// 又出现」，而用户完全不知道为什么。按"最后一段起点"算，空隙里仍然高亮上一句，
/// 这才是"我正听到哪里"的正确回答。
extension Array where Element == TranscriptSegment {

    /// 这批材料里到底有没有说话人信息。
    ///
    /// **抽成一处判据的理由**：它决定两件事 —— 分章 prompt 要不要解释 `[我方]/[对方]`，
    /// 以及速览 / 纪要那一步要不要要求写归属。这两处各写一遍 `contains { $0.speaker != nil }`，
    /// 迟早出现"分章解释了、速览那一步没要求"这种读起来完全正常的静默不一致
    /// （2026-09-17 就是这么栽的）。
    var hasSpeakerLabels: Bool {
        contains { $0.speaker != nil }
    }

    /// 当前段的**序号**。空数组、或 `t` 落在第一段之前（还没开口）时为 nil。
    ///
    /// 二分而不是线性：逐字稿一场会上千段，而这个函数跟着播放头每 0.25 秒被问一次。
    /// 线性虽然也跑得动，但这是"随时可能被放到更热的地方"的那种代码。
    func playheadIndex(at time: TimeInterval) -> Int? {
        guard !isEmpty else { return nil }
        // 第一段还没开始：此刻没有"当前句"可言，别硬指到第一句上 ——
        // 那会让人以为"已经听到第一句了"，而其实播放头还在它前面。
        guard time >= self[0].start else { return nil }

        var low = 0
        var high = count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if self[mid].start <= time {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    /// 当前段本身（原文页要高亮它、要滚到它）。
    func playheadSegment(at time: TimeInterval) -> TranscriptSegment? {
        playheadIndex(at: time).map { self[$0] }
    }
}

struct InsightItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var label: String
    var evidence: String
    var confidence: Double
    var timestamp: TimeInterval?
}

struct ActionItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var label: String
    var priority: PriorityLevel?
    var dueText: String?
    var evidence: String
    var confidence: Double
    var timestamp: TimeInterval?
    /// 「谁来做」。材料里说了才填，没点名就留 nil。
    ///
    /// **必须是 Optional**：一方面老会话里没有这个键，非 Optional 会让升级后
    /// 读不出历史记录；另一方面「没提责任人」和「责任人待定」是两回事，
    /// 用空字符串把两者压成一个值，UI 就没法决定该不该显示那一行。
    /// 放在声明末尾是为了不打断既有 `ActionItem(...)` 调用的参数顺序。
    var owner: String? = nil
}

struct TimelineChunk: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var summary: String
    var evidence: String
    var confidence: Double

    var title: String {
        "\(start.clockLabel) - \(end.clockLabel)"
    }

    /// 时间轨上用的紧凑区间写法：`00:00–01:51`。
    ///
    /// 两条约束：
    /// 1. **字符数恒定在 11 左右**——三页共用的时间轨是固定 96pt 的，
    ///    标签必须保证装得下，否则只能靠缩字号兜底，字号就会一场一个样。
    ///    所以一小时的会开成 `00:00–01:51`，三小时的会开成 `1:00–1:10`：
    ///    区间标签只需要说清"这一段大概在哪"，秒在这里是噪音。
    /// 2. 用 en dash（–）而不是连字符：等宽数字下它落在正中，读起来是"一段"，
    ///    而 `00:00 - 01:51` 中间那两个空格会让它读成"两个数"。
    var rangeLabel: String {
        "\(Self.compactClock(start))–\(Self.compactClock(end))"
    }

    private static func compactClock(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d", hours, minutes)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// 一次整理调用留下的技术痕迹。
///
/// 存在的理由只有一个：**「输出被 token 上限截断」以前是看不见的**。
/// 模型写完半截 JSON 被砍，代码拿这段半截去解析、抛错、整场静默降级成本地规则，
/// 用户在界面上只看到「没有任何结论」，既不知道发生过什么，也没法判断该不该重试。
/// 把 `finish_reason` 存下来之后：评测脚本能一眼看出 `length` 还是 `stop`，
/// 界面也能据此说一句「这次的结果不完整」。
///
/// 只做诊断，不参与展示逻辑（界面用 `partialNotice` 那一句人话）。
struct SummaryDiagnostics: Codable, Hashable, Sendable {
    /// 速览 / 结构化那一次调用的 `finish_reason`（`stop` / `length` / 服务商自定义）。
    var overviewFinishReason: String?
    /// 纪要正文那一次调用的 `finish_reason`。
    var minutesFinishReason: String?
    /// 为了躲开截断而抬预算的次数（>0 说明这次是「差点没产出来」）。
    var escalationCount: Int
    /// 最终交出来的结果是否**缺斤少两**（截断收尾，或缺了某一半）。
    var partial: Bool

    init(
        overviewFinishReason: String? = nil,
        minutesFinishReason: String? = nil,
        escalationCount: Int = 0,
        partial: Bool = false
    ) {
        self.overviewFinishReason = overviewFinishReason
        self.minutesFinishReason = minutesFinishReason
        self.escalationCount = escalationCount
        self.partial = partial
    }
}

struct MeetingAnalysis: Codable, Hashable, Sendable {
    var overview: [InsightItem]
    var timeline: [TimelineChunk]
    var decisions: [InsightItem]
    var actions: [ActionItem]
    var confidence: Double
    var overviewText: String
    var minutesText: String
    var summaryModel: String?
    var summaryError: String?
    /// 「模型交出来的结果不完整」的人话说明。
    ///
    /// 与 `summaryError` 是**两件事**，不要合并：`summaryError` 的含义是
    /// 「模型整个没返回，下面这些是本地保守结果」——它对应的横幅文案是
    /// 「已保留逐字稿；下面仅显示本地保守结果。」把它拿去描述一份"缺了纪要正文、
    /// 但速览和待办都是模型产出的"结果，横幅就说谎了。
    var partialNotice: String?
    /// 见 `SummaryDiagnostics`。老会话没有这个键，解码后为 nil。
    var diagnostics: SummaryDiagnostics?

    /// 一句话结论：这场会**最终**是个什么结果。
    ///
    /// 和 `overviewText` 的区别是「长度」而不是「详略」：速览页最上面那行
    /// 要在不滚动的情况下被读到，所以它必须是一句话，不是一段话。
    /// 取 Optional 的理由同 `owner`：老会话没有这个键。
    var headline: String?
    /// 带时间锚的要点。每条形如「[12:30] 结论…」——`[mm:ss]` 让 UI
    /// 能把它渲染成可点击跳播放的位置，而不是一段只能读的文字。
    var overviewBullets: [String]?
    /// 会上**没定下来**的问题。单独成一栏，是因为"待确认"跟"已决定"混在一张
    /// 列表里时，读者会把悬而未决的条目当成结论。
    var openQuestions: [String]?

    /// **风险与阻塞**：会上点出、可能挡住待办落地的事。
    ///
    /// 为什么单开一个维度、而不是并进 `openQuestions`：
    /// 那个是"**没定下来的问题**"（要人去问），这个是"**已经知道会挡路的事**"
    /// （要人去处理）—— 两者的下一步动作不同，混在一栏里等于把"去问"和"去解"压成一个。
    ///
    /// 类型与 `decisions` 相同（`InsightItem`）：风险同样要能溯源（依据 + 时间锚 + 置信度），
    /// 复用同一套渲染与导出，也就不会出现"决策能跳回放、风险跳不了"这种同屏内的不一致。
    var risks: [InsightItem]?

    /// 材料不足，**压根没调模型**。见 `MaterialShortfall`。
    ///
    /// 与 `summaryError` / `partialNotice` 三者互斥，语义各不同：
    /// 这个是"我们判断过了，这份材料不值得调模型"；那两个是"调了，但没成功 / 没拿全"。
    /// 混成一个字段会让「重试」按钮出现在按了也没用（材料还是那么少）的地方。
    var insufficientMaterial: MaterialShortfall?

    /// 窗口副标题里用的**短模型名**：只留模型，砍掉前半截服务商。
    ///
    /// `summaryModel` 存的是 `SummaryModelSettings.displayName`，格式是
    /// `<服务商> · <模型名>`（如「自定义兼容接口 · deepseek-v4.1-flash」）。
    /// 完整名字在设置面板里有用——那里要交代「这套凭据连的是谁」；
    /// 但窗口副标题只有一行，还要和日期、时长、状态挤在一起，
    /// 服务商名在这里纯是噪音：它又长，又回答不了「这场会是哪个模型整理的」。
    ///
    /// 没有分隔符时（如本地规则档的「本地保守整理」）原样返回。
    var modelLabel: String? {
        guard let raw = summaryModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        guard let separator = raw.range(of: " · ") else { return raw }
        let name = String(raw[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? raw : name
    }

    static let empty = MeetingAnalysis(
        overview: [],
        timeline: [],
        decisions: [],
        actions: [],
        confidence: 0,
        overviewText: "",
        minutesText: "",
        summaryModel: nil,
        summaryError: nil
    )

    init(
        overview: [InsightItem],
        timeline: [TimelineChunk],
        decisions: [InsightItem],
        actions: [ActionItem],
        confidence: Double,
        overviewText: String = "",
        minutesText: String = "",
        summaryModel: String? = nil,
        summaryError: String? = nil,
        partialNotice: String? = nil,
        diagnostics: SummaryDiagnostics? = nil,
        headline: String? = nil,
        overviewBullets: [String]? = nil,
        openQuestions: [String]? = nil,
        insufficientMaterial: MaterialShortfall? = nil,
        risks: [InsightItem]? = nil
    ) {
        self.overview = overview
        self.timeline = timeline
        self.decisions = decisions
        self.actions = actions
        self.confidence = confidence
        self.overviewText = overviewText
        self.minutesText = minutesText
        self.summaryModel = summaryModel
        self.summaryError = summaryError
        self.partialNotice = partialNotice
        self.diagnostics = diagnostics
        self.headline = headline
        self.overviewBullets = overviewBullets
        self.openQuestions = openQuestions
        self.insufficientMaterial = insufficientMaterial
        self.risks = risks
    }

    private enum CodingKeys: String, CodingKey {
        case overview
        case timeline
        case decisions
        case actions
        case confidence
        case overviewText
        case minutesText
        case summaryModel
        case summaryError
        case partialNotice
        case diagnostics
        case headline
        case overviewBullets
        case openQuestions
        case insufficientMaterial
        case risks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overview = try container.decodeIfPresent([InsightItem].self, forKey: .overview) ?? []
        timeline = try container.decodeIfPresent([TimelineChunk].self, forKey: .timeline) ?? []
        decisions = try container.decodeIfPresent([InsightItem].self, forKey: .decisions) ?? []
        actions = try container.decodeIfPresent([ActionItem].self, forKey: .actions) ?? []
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        overviewText = try container.decodeIfPresent(String.self, forKey: .overviewText) ?? ""
        minutesText = try container.decodeIfPresent(String.self, forKey: .minutesText) ?? ""
        summaryModel = try container.decodeIfPresent(String.self, forKey: .summaryModel)
        summaryError = try container.decodeIfPresent(String.self, forKey: .summaryError)
        // 老会话没有这两个键 —— 必须 decodeIfPresent，否则一升级就读不出历史记录。
        partialNotice = try container.decodeIfPresent(String.self, forKey: .partialNotice)
        diagnostics = try container.decodeIfPresent(SummaryDiagnostics.self, forKey: .diagnostics)
        // 2A 新增的三个键同理：老会话没有，必须 decodeIfPresent。
        headline = try container.decodeIfPresent(String.self, forKey: .headline)
        overviewBullets = try container.decodeIfPresent([String].self, forKey: .overviewBullets)
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions)
        // 2C 新增，同理：老会话没有这个键。
        insufficientMaterial = try container.decodeIfPresent(
            MaterialShortfall.self,
            forKey: .insufficientMaterial
        )
        // 页分家那一轮新增（风险与阻塞），同理：老会话没有这个键。
        risks = try container.decodeIfPresent([InsightItem].self, forKey: .risks)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(overview, forKey: .overview)
        try container.encode(timeline, forKey: .timeline)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(actions, forKey: .actions)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(overviewText, forKey: .overviewText)
        try container.encode(minutesText, forKey: .minutesText)
        try container.encodeIfPresent(summaryModel, forKey: .summaryModel)
        try container.encodeIfPresent(summaryError, forKey: .summaryError)
        try container.encodeIfPresent(partialNotice, forKey: .partialNotice)
        try container.encodeIfPresent(diagnostics, forKey: .diagnostics)
        try container.encodeIfPresent(headline, forKey: .headline)
        try container.encodeIfPresent(overviewBullets, forKey: .overviewBullets)
        try container.encodeIfPresent(openQuestions, forKey: .openQuestions)
        try container.encodeIfPresent(insufficientMaterial, forKey: .insufficientMaterial)
        try container.encodeIfPresent(risks, forKey: .risks)
    }

    var hasNarrative: Bool {
        !overviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !minutesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 下面这些内容是**本地保守整理**，不是模型产出（模型压根没返回）。
    var isLocalFallback: Bool {
        summaryError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// 材料太少，**我们主动没调模型**。与 `isLocalFallback` 是两件事：
    /// 那个是"调了没成"，这个是"判断过、不值得调"。空态文案因此不同，
    /// 「重试」也只给前者（材料还是那么少，点几次都一样）。
    var isMaterialInsufficient: Bool { insufficientMaterial != nil }

    /// 这份结果里有没有**结构化发现**（决策 / 待办 / 风险 / 一句话结论 / 要点 / 待确认）。
    ///
    /// 刻意**不**把 `overviewText` / `minutesText` / `timeline` 算进来 ——
    /// 恰好是这三样最多、却又最可能是"模型对着材料介绍自己"的部分。
    /// 2C 修补历史记录时用它当第二把锁：凡是有结构化发现的会话一律不碰。
    var hasStructuredFindings: Bool {
        !decisions.isEmpty
            || !actions.isEmpty
            || headline != nil
            || !(overviewBullets?.isEmpty ?? true)
            || !(openQuestions?.isEmpty ?? true)
            || !(risks?.isEmpty ?? true)
    }

    /// 需要提示用户的那句话（有本地兜底就报兜底，否则报"不完整"）。
    ///
    /// 两件事互斥优先级明确：本地兜底更严重，它意味着界面上**没有一句是模型写的**。
    var noticeMessage: String? {
        if let summaryError, !summaryError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SafeDiagnostics.summary(summaryError)
        }
        if let partialNotice, !partialNotice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SafeDiagnostics.partial(partialNotice)
        }
        return nil
    }

    /// 速览「要点」解析成可渲染的结构。
    ///
    /// 存盘里它是 `[String]`（与 prompt 的输出格式一一对应，评测脚本也能直接比对），
    /// 解析属于**展示层**的事；放在这里只是因为解析规则要能单测 —— View 里测不到。
    var parsedOverviewBullets: [OverviewBullet] {
        (overviewBullets ?? []).map(OverviewBullet.parse)
    }
}

/// 速览「要点」里的一条：`[12:30] 内容`。
///
/// 为什么要把时间锚从正文里拆出来：锚不是内容，它是**一个动作的把手** ——
/// 渲染成可点击的按钮就能跳播放。留在字符串里就只能当文字读。
struct OverviewBullet: Hashable, Identifiable, Sendable {
    /// 括号里的时间锚（秒）。没写、或写不成时间的，是 nil。
    var seconds: TimeInterval?
    /// 去掉时间锚之后的正文。
    var text: String

    var id: String {
        let stamp = seconds.map { String(Int($0)) } ?? "-"
        return "\(stamp)|\(text)"
    }

    /// 有没有可点的锚。没有锚的条目照常渲染，只是那一小段退回纯文字。
    var hasAnchor: Bool { seconds != nil }

    /// `[12:30] 内容` → `(750, "内容")`。
    ///
    /// 宽容三件真实产出里见过的形状：
    /// · **没有时间锚**（纯文本）→ `seconds = nil`，正文原样保留；
    /// · **锚在句子中间**（模型偶尔这么写）→ 不当锚，整条留作正文 ——
    ///   否则会把前半句吃掉；
    /// · **只有锚没有正文** → `text` 为空串，调用方据此跳过这一条。
    ///
    /// 锚的格式接受 `mm:ss` 与 `h:mm:ss`（超过一小时的会），
    /// 中英文方括号混用也认（`[` / `【`）。
    static func parse(_ raw: String) -> OverviewBullet {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opening = trimmed.first, opening == "[" || opening == "【" else {
            return OverviewBullet(seconds: nil, text: trimmed)
        }
        let closing: Character = opening == "[" ? "]" : "】"
        guard let closeIndex = trimmed.firstIndex(of: closing) else {
            return OverviewBullet(seconds: nil, text: trimmed)
        }

        let stampStart = trimmed.index(after: trimmed.startIndex)
        let stamp = trimmed[stampStart..<closeIndex]
        guard let seconds = seconds(fromStamp: stamp) else {
            return OverviewBullet(seconds: nil, text: trimmed)
        }

        let rest = trimmed[trimmed.index(after: closeIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return OverviewBullet(seconds: seconds, text: rest)
    }

    /// 把 `12:30` / `1:02:30` 解成秒。任何一处不是数字就返回 nil。
    private static func seconds(fromStamp stamp: Substring) -> TimeInterval? {
        let parts = stamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var values: [Int] = []
        for part in parts {
            // `Int("")` 是 nil，`Int("1 2")` 也是 nil —— 一句 `Int` 就够了，
            // 不需要额外判空（`:` 打头或结尾会被这里挡掉）。
            guard let value = Int(part.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                return nil
            }
            values.append(value)
        }
        // 两位那档是 mm:ss，三位那档是 h:mm:ss —— 与 `clockLabel` 的输出一一对应。
        if values.count == 2 {
            return Double(values[0]) * 60 + Double(values[1])
        }
        return Double(values[0]) * 3600 + Double(values[1]) * 60 + Double(values[2])
    }
}

struct MeetingSession: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var folderName: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var captureMode: CaptureMode
    var status: MeetingStatus
    var sourceFileName: String
    var inputAudioFileName: String?
    /// 双声道（P2-2a）两路音频的文件名：`local` 是麦克风（我方），`remote` 是系统声（对方）。
    ///
    /// 存下来是为了**重新处理**这条路径 —— 那一条不走录音，只能靠会话记录里这两个名字
    /// 把两路找回来。老会话没有这两个键，所以必须 Optional（合成 `Decodable` 不理会默认值，
    /// 写成非 Optional 会让升级后的所有老会话直接读不出来）。
    var localAudioFileName: String?
    var remoteAudioFileName: String?
    var transcriptText: String
    var transcriptSegments: [TranscriptSegment]
    var analysis: MeetingAnalysis
    var whisperCLIPath: String
    var whisperModelPath: String
    var duration: TimeInterval?
    var errorMessage: String?
    var processingProgress: Double?
    var processingStage: String?
    var processingStartedAt: Date?
    var processingCompletedChunks: Int?
    var processingTotalChunks: Int?
    var processingNextOffset: TimeInterval?
    /// 当前这一段是**什么时候开始转的**。
    ///
    /// 进度条原来只会按段跳（4 段就是 0 → 25% → 50% → 75% → 100%），
    /// 每一段之间十分钟一动不动、然后"啪"地往前一格 —— 用户的原话是
    /// 「过一阵突然往前增一下」。有了这个时间点，界面才能在**段内**平滑推进：
    /// 用「已完成段的实际耗时」当本段的预期耗时，把这一段切成连续的百分比。
    /// 它只用来算显示值，永远不超过 `(已完成段 + 0.92) / 总段数`，
    /// 所以某一段真跑完时进度只会继续往前，不会往回缩。
    var processingChunkStartedAt: Date?
    /// 这场会的逐字稿**被人改过**（最后一次编辑的时间）。
    ///
    /// 它不是"编辑计数"的一个缓存，而是「原文页那句话还成不成立」的判据：
    /// 没改过时页眉说「原汁原味保留转写」，改过之后这句话就成了假话 ——
    /// 必须换一句（同 2C 的 `summaryModel`：留 nil 才是字面事实）。
    ///
    /// 段级标记看 `TranscriptSegment.manuallyEditedAt`；本字段只回答
    /// 「这场会动过没有」，好让不用遍历几百段的界面（页眉、副标题）便宜地拿到结论。
    var transcriptEditedAt: Date?
    /// Persisted across crashes; a retry must never treat old results as new checkpoints.
    var processingRetainsPreviousResults: Bool?
    var analysisStale: Bool?
    var captureWarning: String?
    var lastRegenerationError: String?

    var analysisNotice: String? {
        var notices: [String] = []
        if analysisStale == true { notices.append("原文已更新，速览与纪要基于修改前的内容，请重新整理。") }
        if let message = SafeDiagnostics.summary(lastRegenerationError) { notices.append("本次重新整理未成功，已保留上次结果。" + message) }
        notices.append(contentsOf: [SafeDiagnostics.capture(captureWarning), analysis.noticeMessage].compactMap { $0 })
        return notices.isEmpty ? nil : notices.joined(separator: "；")
    }

    var materialSegments: [TranscriptSegment] {
        if !transcriptSegments.isEmpty { return transcriptSegments }
        let text = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [TranscriptSegment(start: 0, end: duration ?? 0, text: text, confidence: 0.5)]
    }

    static func makeDraft(createdAt date: Date, captureMode: CaptureMode, folderName: String) -> MeetingSession {
        MeetingSession(
            id: UUID(),
            folderName: folderName,
            title: "未命名会议",
            createdAt: date,
            updatedAt: date,
            captureMode: captureMode,
            status: .recording,
            sourceFileName: "source",
            inputAudioFileName: nil,
            transcriptText: "",
            transcriptSegments: [],
            analysis: .empty,
            whisperCLIPath: "",
            whisperModelPath: "",
            duration: nil,
            errorMessage: nil,
            processingProgress: nil,
            processingStage: nil,
            processingStartedAt: nil,
            processingCompletedChunks: nil,
            processingTotalChunks: nil,
            processingNextOffset: nil,
            processingChunkStartedAt: nil
        )
    }
}

extension TimeInterval {
    var clockLabel: String {
        let totalSeconds = isFinite ? Int(min(Double(Int.max / 2), max(0, self.rounded()))) : 0
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// 送进整理模型的时间戳（`12.3`）。
    ///
    /// 原来它是 `SummaryEngine.swift` 里的 `private extension`，`TranscriptSegment.materialLine`
    /// 用不到它 —— 于是"正文拼一遍、分章再拼一遍"。挪到这里是为了让两处共用同一份实现。
    var oneDecimalSeconds: String {
        String(format: "%.1f", max(0, self))
    }
}

extension Double {
    var confidenceLabel: String {
        let value = Int((max(0, min(1, self)) * 100).rounded())
        return "\(value)%"
    }

    var percentLabel: String {
        let value = Int((max(0, min(1, self)) * 100).rounded())
        return "\(value)%"
    }
}

/// 「转写中」进度条的**显示值**估算。
///
/// 管线是"一段一段跑 whisper"，段内没有任何回调，所以 `processingProgress`
/// 只在段边界跳一下——4 段就是 0 → 25 → 50 → 75 → 100，每跳一次隔好几分钟。
/// 用户看到的「过一阵突然往前增一下」就是这个。
///
/// 这里拿**本段已经跑掉的时间**除以**已完成段的平均耗时**，在段内插值，
/// 让进度条连续地爬。三条纪律，缺一不可：
///
/// 1. **只在真实进度之上加**——`max(base, estimated)`，永不回缩；
/// 2. **段内最多补到 `maxIntraChunkFill` 段**——留出余量，进下一段时只会
///    往前跳，不会"先冲过界、再倒吸一口"；
/// 3. **一段都没跑完就不猜**——此时没有平均耗时可用，老实返回 `base`。
///
/// 刻意做成纯函数：**显示**用它，存盘与分支判断一律仍用真实进度。
/// 别把它的返回值写回 `session`。
enum ProcessingProgressEstimator {
    /// 段内最多补到的比例。留 8% 余量给"下一段开头"。
    static let maxIntraChunkFill = 0.92

    static func displayProgress(
        base: Double,
        completedChunks: Int,
        totalChunks: Int,
        startedAt: Date?,
        chunkStartedAt: Date?,
        now: Date
    ) -> Double {
        let clampedBase = max(0, min(1, base))
        guard totalChunks > 0,
              completedChunks > 0,
              completedChunks < totalChunks,
              let startedAt,
              let chunkStartedAt
        else { return clampedBase }

        let perChunk = now.timeIntervalSince(startedAt) / Double(completedChunks)
        // 小于 1 秒的"平均耗时"只可能是时钟抖动，别拿它做除数。
        guard perChunk.isFinite, perChunk > 1 else { return clampedBase }

        let elapsed = max(0, now.timeIntervalSince(chunkStartedAt))
        let withinChunk = min(maxIntraChunkFill, elapsed / perChunk)
        let estimated = (Double(completedChunks) + withinChunk) / Double(totalChunks)
        return max(clampedBase, min(1, estimated))
    }
}

extension String {
    var trimmedLines: String {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
