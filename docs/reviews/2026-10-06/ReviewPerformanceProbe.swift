import XCTest
@testable import MeetingScribe

final class ReviewPerformanceProbe: XCTestCase {
    func testLookupComparison() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-perf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var records: [MeetingSession] = []
        for index in 0..<100 {
            var session = try storage.createDraftSession(captureMode: .imported)
            session.status = .ready
            session.title = "合成会议 \(index)"
            session.transcriptSegments = (0..<300).map { i in TranscriptSegment(start: Double(i), end: Double(i + 1), text: "合成审查材料：这是没有真实客户信息的性能样本。", confidence: 0.9) }
            session.transcriptText = session.transcriptSegments.map(\.text).joined(separator: "\n")
            try storage.save(session)
            records.append(session)
        }
        let baseline = BaselineDirectoryStorage(rootURL: root)
        let order = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let lastName = try XCTUnwrap(order.last?.lastPathComponent)
        let target = try XCTUnwrap(records.first { $0.folderName == lastName })
        let start = Date()
        for _ in 0..<20 { XCTAssertEqual(try baseline.session(with: target.id).id, target.id) }
        let old = Date().timeIntervalSince(start)
        let next = Date()
        for _ in 0..<20 { XCTAssertEqual(try storage.session(with: target.id).id, target.id) }
        let new = Date().timeIntervalSince(next)
        print("PERFORMANCE audit: 100 meetings x 300 segments; 20 last-folder lookups; baseline=\(old)s, indexed=\(new)s, ratio=\(old / max(new, 0.000001))")
    }
}

private struct BaselineDirectoryStorage {
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
            title: Self.defaultTitle(for: createdAt),
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

    func playbackURL(for session: MeetingSession) -> URL? {
        let candidates: [String]
        if session.captureMode == .imported {
            // 导入会议要优先播放用户原始音频。
            // `input.wav` 是给 whisper 准备的 16 kHz 单声道中间文件，音质差、也更容易被
            // 后续重处理覆盖；如果它先被播放器拿到，一旦系统播放器不认这份中间 WAV，
            // 用户明明导入了原音频，底栏也会显示成“暂无可播放音频”。
            candidates = [session.sourceFileName, session.inputAudioFileName, "input.wav"].compactMap { $0 }
        } else {
            candidates = [session.inputAudioFileName, "input.wav", session.sourceFileName].compactMap { $0 }
        }

        var seen = Set<String>()
        for name in candidates where !name.isEmpty && seen.insert(name).inserted {
            let url = sourceURL(for: session, preferredFileName: name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
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

    /// 数据根。默认是 `~/Library/Application Support/MeetingScribe`。
    ///
    /// **可以用环境变量 `MS_DATA_ROOT` 覆盖，指向一个隔离目录。**
    ///
    /// 这条覆盖不是给用户用的，是给**界面验证**用的：要截一张"会话列表里有内容"
    /// 或"速览页有结论和要点"的图，就得先有一场那样的会 —— 而往用户真实的
    /// 数据根里塞夹具，代价已经被证明过一次（见 `docs/未解决问题与正确做法.md`：
    /// 真实数据根被整目录级移除，无备份可恢复）。有了这个开关，夹具永远活在
    /// 临时目录里，真实根**一次都不被写**。
    ///
    /// 取不到、或取到空串时静默回落 —— 一个拼错的环境变量不该让 App 起不来。
    private static func defaultRootURL() -> URL {
        let fallback = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("MeetingScribe", isDirectory: true)

        guard let override = ProcessInfo.processInfo.environment["MS_DATA_ROOT"],
              !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fallback }
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    private static func folderName(for date: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: date)
        return "\(stamp)_\(id.uuidString.prefix(8))"
    }

    private static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return "会议 \(formatter.string(from: date))"
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
