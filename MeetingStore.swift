import AppKit
import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    @Published var sessions: [MeetingSession] = []
    @Published var selectedSessionID: UUID?
    @Published var captureMode: CaptureMode {
        didSet {
            guard oldValue != captureMode else { return }
            UserDefaults.standard.set(captureMode.rawValue, forKey: Preferences.captureMode)
        }
    }
    @Published var whisperCLIPath: String
    @Published var whisperModelPath: String
    @Published var statusText: String = "准备就绪"
    @Published var isRecording: Bool = false
    @Published var isProcessing: Bool = false
    @Published var showSettings: Bool = false
    @Published var importAudioPresented: Bool = false
    @Published var errorMessage: String?

    private let storage = SessionStorage()
    private let transcoder = AudioTranscoder()
    private let transcriber = WhisperCLIRunner()
    private var microphoneSession: MicrophoneRecordingSession?
    private var mixedSession: MixedRecordingSession?
    private var activeSessionID: UUID?

    private enum Preferences {
        static let captureMode = "meetingScribe.captureMode"
        static let whisperCLIPath = "meetingScribe.whisperCLIPath"
        static let whisperModelPath = "meetingScribe.whisperModelPath"
    }

    init() {
        let defaults = Self.defaultRuntimePaths()
        captureMode = CaptureMode(
            rawValue: UserDefaults.standard.string(forKey: Preferences.captureMode) ?? ""
        ) ?? .mixed
        whisperCLIPath = UserDefaults.standard.string(forKey: Preferences.whisperCLIPath) ?? defaults.cliURL.path
        whisperModelPath = UserDefaults.standard.string(forKey: Preferences.whisperModelPath) ?? defaults.modelURL.path
        reloadSessions()
    }

    var selectedSession: MeetingSession? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID }
    }

    var workspaceSession: MeetingSession? {
        if let selectedSession, selectedSession.status != .failed {
            return selectedSession
        }
        return sessions.first { $0.status != .failed }
    }

    func reloadSessions() {
        sessions = storage.loadSessions()
        if selectedSessionID == nil {
            selectedSessionID = sessions.first?.id
        } else if sessions.contains(where: { $0.id == selectedSessionID }) == false {
            selectedSessionID = sessions.first?.id
        }
    }

    func startRecording() {
        guard !isRecording, !isProcessing else { return }

        if captureMode == .imported {
            importAudioPresented = true
            statusText = "请选择要导入的音频。"
            return
        }

        let draft = storage.createDraftSession(captureMode: captureMode)
        sessions.insert(draft, at: 0)
        selectedSessionID = draft.id
        activeSessionID = draft.id
        errorMessage = nil
        statusText = "正在准备录音..."
        savePreferences()

        switch captureMode {
        case .microphone:
            let recorder = MicrophoneRecordingSession(outputURL: storage.sourceURL(for: draft, preferredFileName: "source.wav"))
            microphoneSession = recorder
            Task {
                do {
                    try await recorder.start()
                    await MainActor.run {
                        self.isRecording = true
                        self.statusText = "正在录音"
                        self.updateSessionStatus(draft.id, status: .recording)
                    }
                } catch {
                    await MainActor.run {
                        self.failSession(draft.id, message: error.localizedDescription)
                    }
                }
            }
        case .mixed:
            let recorder = MixedRecordingSession(movieURL: storage.sourceURL(for: draft, preferredFileName: "source.mov"))
            mixedSession = recorder
            Task {
                do {
                    try await recorder.start()
                    await MainActor.run {
                        self.isRecording = true
                        self.statusText = "正在混录"
                        self.updateSessionStatus(draft.id, status: .recording)
                    }
                } catch {
                    await MainActor.run {
                        self.failSession(draft.id, message: error.localizedDescription)
                    }
                }
            }
        case .imported:
            break
        }
    }

    func stopRecording() {
        guard isRecording, let sessionID = activeSessionID else { return }
        isRecording = false
        isProcessing = true
        statusText = "正在整理录音..."

        Task {
            do {
                let session = try storage.session(with: sessionID)
                let sourceURL = storage.sourceURL(for: session, preferredFileName: session.sourceFileName)
                let inputURL: URL

                switch session.captureMode {
                case .microphone:
                    inputURL = sourceURL
                    _ = microphoneSession?.stop()
                    microphoneSession = nil
                case .mixed:
                    _ = try await mixedSession?.stop()
                    mixedSession = nil
                    inputURL = storage.inputURL(for: session, preferredFileName: "input.wav")
                    try transcoder.convertToWav(inputURL: sourceURL, outputURL: inputURL)
                case .imported:
                    inputURL = sourceURL
                }

                await process(sessionID: session.id, sourceURL: sourceURL, inputURL: inputURL)
            } catch {
                await MainActor.run {
                    self.failProcessing(message: error.localizedDescription)
                }
            }
        }
    }

    func importAudio(url: URL) {
        guard !isRecording, !isProcessing else { return }
        do {
            let draft = storage.createDraftSession(captureMode: .imported)
            sessions.insert(draft, at: 0)
            selectedSessionID = draft.id
            activeSessionID = draft.id
            errorMessage = nil
            statusText = "正在导入音频..."
            savePreferences()

            let copiedSource = try storage.copyImportedAudio(url: url, into: draft)
            Task {
                do {
                    let inputURL = storage.inputURL(for: draft, preferredFileName: "input.wav")
                    try transcoder.convertToWav(inputURL: copiedSource, outputURL: inputURL)
                    await process(sessionID: draft.id, sourceURL: copiedSource, inputURL: inputURL)
                } catch {
                    await MainActor.run {
                        self.failSession(draft.id, message: error.localizedDescription)
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    func openSelectedSessionFolder() {
        guard let session = selectedSession else { return }
        let folderURL = storage.folderURL(for: session)
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    func refreshPreferences() {
        savePreferences()
    }

    func deleteSession(_ session: MeetingSession) {
        do {
            try storage.delete(session)
            sessions.removeAll { $0.id == session.id }
            if selectedSessionID == session.id {
                selectedSessionID = sessions.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    private func process(sessionID: UUID, sourceURL: URL, inputURL: URL) async {
        do {
            guard let cliURL = resolvedWhisperCLIURL(), let modelURL = resolvedModelURL() else {
                throw PipelineError.missingBinary
            }

            await MainActor.run {
                self.updateSessionStatus(sessionID, status: .processing)
                self.statusText = "正在转写..."
            }

            let transcript = try await transcriber.transcribe(
                audioURL: inputURL,
                cliURL: cliURL,
                modelURL: modelURL,
                language: "zh"
            )
            let analysis = MeetingAnalysisBuilder.build(from: transcript.segments)

            var session = try storage.session(with: sessionID)
            session.status = .ready
            session.updatedAt = Date()
            session.transcriptSegments = transcript.segments
            session.transcriptText = transcript.text.trimmedLines
            session.analysis = analysis
            session.inputAudioFileName = inputURL.lastPathComponent
            session.whisperCLIPath = cliURL.path
            session.whisperModelPath = modelURL.path
            session.duration = transcript.segments.last?.end
            session.errorMessage = nil
            session.title = MeetingAnalysisBuilder.title(for: session, transcript: transcript)

            try storage.save(session)

            await MainActor.run {
                self.replaceSession(session)
                self.selectedSessionID = session.id
                self.statusText = "已完成"
                self.isProcessing = false
                self.activeSessionID = nil
            }
        } catch {
            await MainActor.run {
                self.failProcessing(message: error.localizedDescription)
            }
        }
    }

    private func replaceSession(_ session: MeetingSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
        sessions.sort { $0.createdAt > $1.createdAt }
    }

    private func failSession(_ sessionID: UUID, message: String) {
        do {
            let session = try storage.session(with: sessionID)
            try storage.delete(session)
            sessions.removeAll { $0.id == session.id }
            if selectedSessionID == session.id {
                selectedSessionID = sessions.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        statusText = message
        isRecording = false
        isProcessing = false
        activeSessionID = nil
        microphoneSession = nil
        mixedSession = nil
    }

    private func failProcessing(message: String) {
        if let activeSessionID, var session = try? storage.session(with: activeSessionID) {
            session.status = .failed
            session.errorMessage = message
            session.updatedAt = Date()
            try? storage.save(session)
            replaceSession(session)
        }
        errorMessage = message
        statusText = message
        isRecording = false
        isProcessing = false
        activeSessionID = nil
        microphoneSession = nil
        mixedSession = nil
    }

    private func updateSessionStatus(_ sessionID: UUID, status: MeetingStatus) {
        guard var session = try? storage.session(with: sessionID) else { return }
        session.status = status
        session.updatedAt = Date()
        try? storage.save(session)
        replaceSession(session)
    }

    private func savePreferences() {
        UserDefaults.standard.set(captureMode.rawValue, forKey: Preferences.captureMode)
        UserDefaults.standard.set(whisperCLIPath, forKey: Preferences.whisperCLIPath)
        UserDefaults.standard.set(whisperModelPath, forKey: Preferences.whisperModelPath)
    }

    private func resolvedWhisperCLIURL() -> URL? {
        let candidate = URL(fileURLWithPath: whisperCLIPath)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return Self.defaultRuntimePaths().cliURL
    }

    private func resolvedModelURL() -> URL? {
        let candidate = URL(fileURLWithPath: whisperModelPath)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return Self.defaultRuntimePaths().modelURL
    }

    static func defaultRuntimePaths() -> (cliURL: URL, modelURL: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let whisperRoot = home
            .appendingPathComponent("Documents/Codex/易运盈/outputs/crm-mall-flow/whisper.cpp")
        let cli = whisperRoot.appendingPathComponent("build/bin/whisper-cli")
        let model = whisperRoot.appendingPathComponent("models/ggml-small.bin")
        return (cli, model)
    }
}

struct SessionStorage {
    private let rootURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootURL: URL? = nil) {
        let base = rootURL ?? Self.defaultRootURL()
        self.rootURL = base
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func loadSessions() -> [MeetingSession] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return items.compactMap { folderURL in
            loadSession(from: folderURL)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func createDraftSession(captureMode: CaptureMode) -> MeetingSession {
        let createdAt = Date()
        let id = UUID()
        let folderName = Self.folderName(for: createdAt, id: id)
        let session = MeetingSession(
            id: id,
            folderName: folderName,
            title: Self.defaultTitle(for: createdAt, captureMode: captureMode),
            createdAt: createdAt,
            updatedAt: createdAt,
            captureMode: captureMode,
            status: .recording,
            sourceFileName: Self.sourceFileName(for: captureMode),
            inputAudioFileName: nil,
            transcriptText: "",
            transcriptSegments: [],
            analysis: .empty,
            whisperCLIPath: "",
            whisperModelPath: "",
            duration: nil,
            errorMessage: nil
        )

        do {
            try FileManager.default.createDirectory(at: folderURL(for: session), withIntermediateDirectories: true)
            try save(session)
        } catch {
            // If the save fails, return the in-memory session and let the caller surface the error.
        }

        return session
    }

    func session(with id: UUID) throws -> MeetingSession {
        let folderURLs = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for folderURL in folderURLs {
            guard let session = loadSession(from: folderURL), session.id == id else { continue }
            return session
        }
        throw PipelineError.transcriptionFailed("找不到会话。")
    }

    func save(_ session: MeetingSession) throws {
        try FileManager.default.createDirectory(at: folderURL(for: session), withIntermediateDirectories: true)
        let data = try encoder.encode(session)
        try data.write(to: sessionFileURL(for: session), options: [.atomic])
    }

    func delete(_ session: MeetingSession) throws {
        let folderURL = self.folderURL(for: session)
        if FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.removeItem(at: folderURL)
        }
    }

    func folderURL(for session: MeetingSession) -> URL {
        rootURL.appendingPathComponent(session.folderName, isDirectory: true)
    }

    func sourceURL(for session: MeetingSession, preferredFileName: String) -> URL {
        folderURL(for: session).appendingPathComponent(preferredFileName)
    }

    func inputURL(for session: MeetingSession, preferredFileName: String) -> URL {
        folderURL(for: session).appendingPathComponent(preferredFileName)
    }

    func copyImportedAudio(url: URL, into session: MeetingSession) throws -> URL {
        let destination = sourceURL(for: session, preferredFileName: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        var updated = session
        updated.sourceFileName = destination.lastPathComponent
        try save(updated)
        return destination
    }

    private func loadSession(from folderURL: URL) -> MeetingSession? {
        let fileURL = folderURL.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(MeetingSession.self, from: data)
    }

    private func sessionFileURL(for session: MeetingSession) -> URL {
        folderURL(for: session).appendingPathComponent("session.json")
    }

    private static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MeetingScribe", isDirectory: true)
    }

    private static func folderName(for date: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: date)
        return "\(stamp)_\(id.uuidString.prefix(8))"
    }

    private static func defaultTitle(for date: Date, captureMode: CaptureMode) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return "会议 \(formatter.string(from: date)) · \(captureMode.shortTitle)"
    }

    private static func sourceFileName(for captureMode: CaptureMode) -> String {
        switch captureMode {
        case .microphone:
            return "source.wav"
        case .mixed:
            return "source.mov"
        case .imported:
            return "source"
        }
    }
}

enum MeetingAnalysisBuilder {
    static func title(for session: MeetingSession, transcript: WhisperTranscript) -> String {
        if let first = buildOverview(from: transcript.segments).first {
            let prefix = first.label.prefix(24)
            return "会议 \(prefix)"
        }
        return session.title
    }

    static func build(from segments: [TranscriptSegment]) -> MeetingAnalysis {
        let overview = buildOverview(from: segments)
        let timeline = buildTimeline(from: segments)
        let decisions = buildDecisions(from: segments)
        let actions = buildActions(from: segments)

        let scores = overview.map(\.confidence) + decisions.map(\.confidence) + actions.map(\.confidence)
        let confidence = scores.isEmpty ? 0.5 : scores.reduce(0, +) / Double(scores.count)

        return MeetingAnalysis(
            overview: overview,
            timeline: timeline,
            decisions: decisions,
            actions: actions,
            confidence: confidence
        )
    }

    private static func buildOverview(from segments: [TranscriptSegment]) -> [InsightItem] {
        let candidates = segments
            .filter { $0.text.count > 8 }
            .map { segment in
                (
                    segment,
                    overviewScore(for: segment)
                )
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.start < rhs.0.start
                }
                return lhs.1 > rhs.1
            }

        var items: [InsightItem] = []
        var occupiedRanges: [ClosedRange<Double>] = []
        for (segment, score) in candidates {
            let start = segment.start
            let confidence = min(1, max(0.3, segment.confidence * 0.8 + score * 0.04))
            guard confidence >= 0.4 else { continue }

            if occupiedRanges.contains(where: { range in
                abs(range.lowerBound - start) < 180 || range.contains(start)
            }) {
                continue
            }

            let label = shorten(segment.text, limit: 42)
            items.append(
                InsightItem(
                    label: label,
                    evidence: segment.text,
                    confidence: confidence,
                    timestamp: segment.start
                )
            )
            occupiedRanges.append((segment.start - 180)...(segment.start + 180))
            if items.count == 4 { break }
        }

        if items.isEmpty {
            items = segments.prefix(3).map {
                InsightItem(
                    label: shorten($0.text, limit: 42),
                    evidence: $0.text,
                    confidence: max(0.45, $0.confidence),
                    timestamp: $0.start
                )
            }
        }

        return items
    }

    private static func buildTimeline(from segments: [TranscriptSegment]) -> [TimelineChunk] {
        let grouped = Dictionary(grouping: segments) { Int($0.start / 300) }
        return grouped.keys.sorted().compactMap { bucket in
            guard let bucketSegments = grouped[bucket], let first = bucketSegments.first else { return nil }
            let last = bucketSegments.last ?? first
            let summary = bucketSegments
                .sorted { $0.confidence > $1.confidence }
                .prefix(2)
                .map { shorten($0.text, limit: 28) }
                .joined(separator: "；")
            let evidence = bucketSegments.prefix(2).map(\.text).joined(separator: " / ")
            let avg = bucketSegments.map(\.confidence).reduce(0, +) / Double(bucketSegments.count)
            return TimelineChunk(
                start: first.start,
                end: last.end,
                summary: summary.isEmpty ? shorten(first.text, limit: 28) : summary,
                evidence: evidence,
                confidence: avg
            )
        }
    }

    private static func buildDecisions(from segments: [TranscriptSegment]) -> [InsightItem] {
        let keywords = ["决定", "确认", "定为", "通过", "采用", "改成", "就这样", "先这样", "不需要", "保留", "取消", "落地", "统一"]
        return uniqueMatches(in: segments, keywords: keywords)
    }

    private static func buildActions(from segments: [TranscriptSegment]) -> [ActionItem] {
        let keywords = ["需要", "尽快", "今天", "明天", "本周", "下周", "后天", "负责", "跟进", "整理", "补充", "发给", "提交", "排期", "确认", "同步", "准备"]
        let matches = uniqueMatches(in: segments, keywords: keywords)
        return matches.compactMap { item in
            let priority = priority(from: item.label, confidence: item.confidence)
            let dueText = dueText(from: item.evidence)
            guard item.confidence >= 0.45 || dueText != nil else { return nil }
            return ActionItem(
                label: item.label,
                priority: priority,
                dueText: dueText,
                evidence: item.evidence,
                confidence: item.confidence,
                timestamp: item.timestamp
            )
        }
    }

    private static func uniqueMatches(in segments: [TranscriptSegment], keywords: [String]) -> [InsightItem] {
        var seen = Set<String>()
        var items: [InsightItem] = []

        for segment in segments {
            let text = segment.text
            guard keywords.contains(where: { text.contains($0) }) else { continue }

            let label = shorten(text, limit: 44)
            let normalized = label.replacingOccurrences(of: " ", with: "")
            guard seen.insert(normalized).inserted else { continue }

            let confidence = min(1, max(0.4, segment.confidence))
            items.append(
                InsightItem(
                    label: label,
                    evidence: text,
                    confidence: confidence,
                    timestamp: segment.start
                )
            )

            if items.count == 5 { break }
        }

        return items
    }

    private static func priority(from text: String, confidence: Double) -> PriorityLevel? {
        let urgent = ["必须", "务必", "尽快", "马上", "今天", "立即", "优先", "先做"]
        let soon = ["本周", "下周", "近期", "早点", "尽量"]

        if urgent.contains(where: text.contains) {
            return .p1
        }
        if soon.contains(where: text.contains) || confidence < 0.7 {
            return .p2
        }
        return .p3
    }

    private static func dueText(from text: String) -> String? {
        let patterns = [
            #"\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?"#,
            #"\d{1,2}月\d{1,2}日"#,
            #"今天"#,
            #"明天"#,
            #"后天"#,
            #"本周"#,
            #"下周"#,
            #"月底"#,
            #"周[一二三四五六日天]"#
        ]

        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return String(text[range])
            }
        }
        return nil
    }

    private static func overviewScore(for segment: TranscriptSegment) -> Double {
        let text = segment.text
        let keywordBonus = [
            "目标", "目的", "结论", "方案", "需求", "问题", "风险", "下一步", "安排", "确认", "落地", "重点", "待办"
        ].reduce(0.0) { partial, keyword in
            partial + (text.contains(keyword) ? 1.0 : 0.0)
        }
        let earlyBonus = segment.start < 900 ? 1.2 : 0
        let middleBonus = text.count > 20 ? 0.8 : 0.3
        return keywordBonus * 2 + earlyBonus + middleBonus + segment.confidence * 2
    }

    private static func shorten(_ text: String, limit: Int) -> String {
        let clean = text
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "？", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count <= limit { return clean }
        return String(clean.prefix(limit)) + "…"
    }
}
