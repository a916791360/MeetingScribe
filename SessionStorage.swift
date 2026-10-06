import Foundation

final class SessionStorage: @unchecked Sendable {
    private let indexLock = NSLock()
    // Serializes complete file operations, including nested save/read calls.
    private let ioLock = NSRecursiveLock()
    private var foldersByID: [UUID: URL] = [:]
    var dataDirectoryURL: URL { rootURL }
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        let base = rootURL ?? Self.defaultRootURL()
        self.rootURL = base.resolvingSymlinksInPath().standardizedFileURL
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func loadSessions() -> [MeetingSession] { loadSessionsReport().sessions }

    func loadSessionsReport() -> (sessions: [MeetingSession], issues: [String]) {
        ioLock.lock()
        defer { ioLock.unlock() }
        do {
            let items = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var sessions: [MeetingSession] = []
            var issues: [String] = []
            var loadedIDs = Set<UUID>()
            for folder in items {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                do {
                    let session = try readSession(from: folder, migrate: true) { _ in
                        issues.append(folder.lastPathComponent + "（历史诊断清理未能写入，当前展示已隐藏原内容）")
                    }
                    guard loadedIDs.insert(session.id).inserted else { throw StorageError.invalidManifest }
                    sessions.append(session)
                    indexLock.withLock { foldersByID[session.id] = folder }
                } catch { issues.append(folder.lastPathComponent) }
            }
            return (sessions.sorted { $0.createdAt > $1.createdAt }, issues)
        } catch { return ([], ["无法读取会议目录，请检查磁盘与访问权限"]) }
    }

    func createDraftSession(captureMode: CaptureMode) throws -> MeetingSession {
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

        try save(session)

        return session
    }

    func session(with id: UUID) throws -> MeetingSession {
        ioLock.lock()
        defer { ioLock.unlock() }
        if let folder = indexLock.withLock({ foldersByID[id] }) {
            let session = try readSession(from: folder)
            guard session.id == id else { throw StorageError.invalidManifest }
            return session
        }
        guard let session = loadSessions().first(where: { $0.id == id }) else {
            throw PipelineError.transcriptionFailed("找不到会话。")
        }
        return session
    }

    func save(_ session: MeetingSession) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        let session = session.sanitizingDiagnostics
        let folder = try checkedFolder(for: session)
        for name in [session.sourceFileName, session.inputAudioFileName, session.localAudioFileName, session.remoteAudioFileName].compactMap({ $0 }) {
            _ = try checkedFile(in: folder, name: name)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: checkedFile(in: folder, name: "session.json"), options: [.atomic])
        indexLock.withLock { foldersByID[session.id] = folder }
    }

    func delete(_ session: MeetingSession) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        let folderURL = try checkedFolder(for: session)
        if FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.removeItem(at: folderURL)
        }
        _ = indexLock.withLock { foldersByID.removeValue(forKey: session.id) }
    }

    func folderURL(for session: MeetingSession) -> URL {
        (try? checkedFolder(for: session)) ?? URL(fileURLWithPath: "/dev/null/rejected-path")
    }

    func sourceURL(for session: MeetingSession, preferredFileName: String) -> URL {
        (try? checkedFile(in: checkedFolder(for: session), name: preferredFileName)) ?? URL(fileURLWithPath: "/dev/null/rejected-path")
    }

    func inputURL(for session: MeetingSession, preferredFileName: String) -> URL {
        (try? checkedFile(in: checkedFolder(for: session), name: preferredFileName)) ?? URL(fileURLWithPath: "/dev/null/rejected-path")
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
        ioLock.lock()
        defer { ioLock.unlock() }
        // Never reuse the normalized output or overwrite the session manifest.
        let name = url.lastPathComponent
        guard name.lowercased() != "session.json" else { throw StorageError.invalidPath }
        let storedName = name.lowercased() == "input.wav" ? "imported-original.wav" : name
        let destination = try checkedFile(in: checkedFolder(for: session), name: storedName)
        if url.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL {
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".import-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: url, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        }
        var updated = session
        updated.sourceFileName = destination.lastPathComponent
        try save(updated)
        return destination
    }

    enum StorageError: LocalizedError {
        case invalidPath, invalidManifest
        var errorDescription: String? { "会议文件路径或记录不合法，已停止操作并保留原文件。" }
    }

    private static func isComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private func checkedFolder(for session: MeetingSession) throws -> URL {
        guard Self.isComponent(session.folderName) else { throw StorageError.invalidPath }
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let folder = root.appendingPathComponent(session.folderName, isDirectory: true)
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path == folder.path else { throw StorageError.invalidPath }
        return folder
    }

    private func checkedFile(in folder: URL, name: String) throws -> URL {
        guard Self.isComponent(name) else { throw StorageError.invalidPath }
        let url = folder.appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path else { throw StorageError.invalidPath }
        return url
    }

    private func readSession(from originalFolder: URL, migrate: Bool = false,
                             onMigrationFailure: ((Error) -> Void)? = nil) throws -> MeetingSession {
        guard (try originalFolder.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw StorageError.invalidPath }
        let folder = originalFolder.resolvingSymlinksInPath().standardizedFileURL
        let file = try checkedFile(in: folder, name: "session.json")
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32 * 1024 * 1024 else { throw StorageError.invalidManifest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(MeetingSession.self, from: Data(contentsOf: file))
        guard session.folderName == folder.lastPathComponent,
              try checkedFolder(for: session).path == folder.standardizedFileURL.path else { throw StorageError.invalidManifest }
        for name in [session.sourceFileName, session.inputAudioFileName, session.localAudioFileName, session.remoteAudioFileName].compactMap({ $0 }) {
            _ = try checkedFile(in: folder, name: name)
        }
        let sanitized = session.sanitizingDiagnostics
        if migrate && sanitized != session {
            do { try save(sanitized) }
            catch { onMigrationFailure?(error) }
        }
        return sanitized
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
