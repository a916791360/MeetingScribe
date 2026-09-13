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

struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var confidence: Double

    var timeLabel: String {
        "\(start.clockLabel) - \(end.clockLabel)"
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
        insufficientMaterial: MaterialShortfall? = nil
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

    /// 这份结果里有没有**结构化发现**（决策 / 待办 / 一句话结论 / 要点 / 待确认）。
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
    }

    /// 需要提示用户的那句话（有本地兜底就报兜底，否则报"不完整"）。
    ///
    /// 两件事互斥优先级明确：本地兜底更严重，它意味着界面上**没有一句是模型写的**。
    var noticeMessage: String? {
        if let summaryError, !summaryError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summaryError
        }
        if let partialNotice, !partialNotice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return partialNotice
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
            return TimeInterval(values[0] * 60 + values[1])
        }
        return TimeInterval(values[0] * 3600 + values[1] * 60 + values[2])
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
        let totalSeconds = max(0, Int(self.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
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
