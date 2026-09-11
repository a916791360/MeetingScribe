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
            processingNextOffset: nil
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

extension String {
    var trimmedLines: String {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
