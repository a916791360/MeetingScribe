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
        summaryError: String? = nil
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
    }

    var hasNarrative: Bool {
        !overviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !minutesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
