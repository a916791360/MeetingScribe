import XCTest
@testable import MeetingScribe

final class ReviewBatch4ReproTests: XCTestCase {
    private let fakeKey = "REVIEW_SYNTHETIC_CREDENTIAL_NOT_A_REAL_KEY"

    private func segments() -> [TranscriptSegment] {
        (0..<6).map { i in
            TranscriptSegment(start: Double(i * 10), end: Double(i * 10 + 10),
                text: "REVIEW_SYNTHETIC_MEETING_MARKER 第\(i)段。这是隔离的合成会议材料，报价安排和接口验收都在下周完成。本次审查只验证程序的网络边界，不含任何实际客户信息。", confidence: 0.9)
        }
    }

    private static func rootURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-batch4-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private struct Server {
        let process: Process
        let root: URL
        let origin: Int
        let recipient: Int
        func stop() {
            process.terminate()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        func requests() throws -> [[String: Any]] {
            let text = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            return try text.split(separator: "\n").map { line in
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
        }
    }

    private static func startServer() async throws -> Server {
        let root = try rootURL()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.arguments = ["python3", repo.appendingPathComponent("docs/reviews/2026-10-06/batch-04-server.py").path, root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<200 {
            let portURL = root.appendingPathComponent("ports.json")
            if let data = try? Data(contentsOf: portURL),
               let ports = try? JSONDecoder().decode([String: Int].self, from: data),
               let origin = ports["origin"], let recipient = ports["recipient"] {
                return Server(process: process, root: root, origin: origin, recipient: recipient)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        throw NSError(domain: "ReviewFixture", code: 1)
    }

    private func settings(_ server: Server, path: String) -> SummaryModelSettings {
        SummaryModelSettings(provider: .custom, modelName: "synthetic-review-model", endpoint: "http://127.0.0.1:\(server.origin)/\(path)")
    }

    func testCrossOrigin307ForwardsSyntheticMeetingAndAuthorization() async throws {
        let server = try await Self.startServer()
        defer { server.stop() }
        _ = try await MeetingSummaryEngine().analyze(segments: segments(), settings: settings(server, path: "redirect"), apiKey: fakeKey)
        let received = try server.requests().filter { $0["port"] as? Int == server.recipient }
        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.allSatisfy { ($0["body"] as? String)?.contains("REVIEW_SYNTHETIC_MEETING_MARKER") == true })
        let credentialForwarded = received.contains { $0["authorization"] as? String == "Bearer \(fakeKey)" }
        print("BATCH4 redirect: two POST bodies reached different origin port; authorization forwarded=\(credentialForwarded)")
    }

    func testPrematureSSEEOFIsAcceptedAsCompleteMinutes() async throws {
        let server = try await Self.startServer()
        defer { server.stop() }
        let analysis = try await MeetingSummaryEngine().analyze(segments: segments(), settings: settings(server, path: "eof"), apiKey: fakeKey)
        XCTAssertTrue(analysis.minutesText.contains("后续内容尚未生成"))
        XCTAssertNil(analysis.partialNotice)
        XCTAssertEqual(analysis.diagnostics?.partial, false)
        XCTAssertNil(analysis.diagnostics?.minutesFinishReason)
        XCTAssertEqual(try server.requests().count, 2)
        print("BATCH4 SSE EOF: partial minutes accepted, diagnostics.partial=false, no finish_reason or DONE")
    }

    func testIgnoredStreamFlagCausesFourSuccessfulBillableRequests() async throws {
        let server = try await Self.startServer()
        defer { server.stop() }
        try await MeetingSummaryEngine().test(settings: settings(server, path: "buffered"), apiKey: fakeKey)
        let requests = try server.requests()
        XCTAssertEqual(requests.count, 4)
        let flags = try requests.map { request -> Bool in
            let body = try XCTUnwrap(request["body"] as? String)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            return try XCTUnwrap(json["stream"] as? Bool)
        }
        XCTAssertEqual(flags, [true, true, true, false])
        print("BATCH4 buffered gateway: four HTTP 200 generations, stream flags=\(flags)")
    }

    @MainActor
    func testEchoedSyntheticCredentialIsPersistedAndExported() async throws {
        let server = try await Self.startServer()
        defer { server.stop() }
        let prefKeys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let backup = prefKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in backup {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let dataRoot = server.root.appendingPathComponent("meetings")
        let storage = SessionStorage(rootURL: dataRoot)
        var session = storage.createDraftSession(captureMode: .imported)
        session.status = .ready
        session.transcriptSegments = segments()
        session.transcriptText = segments().map(\.text).joined(separator: "\n")
        session.analysis = MeetingAnalysis(overview: [], timeline: [], decisions: [], actions: [], confidence: 0.9, minutesText: "合成旧纪要", summaryModel: "审查模型")
        try storage.save(session)
        let store = MeetingStore(storage: storage)
        store.summarySettings = settings(server, path: "error")
        store.summaryAPIKeyInput = fakeKey // Memory only; never calls saveSummaryAPIKey or actual Keychain write.
        store.regenerateSummary(for: session)
        for _ in 0..<1200 {
            if !store.isProcessing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isProcessing)
        let saved = try storage.session(with: session.id)
        XCTAssertTrue(saved.analysis.summaryError?.contains(fakeKey) == true)
        XCTAssertTrue(MeetingExporter.markdown(for: saved).contains(fakeKey))
        print("BATCH4 error echo: synthetic credential persisted in session.json and copied into Markdown")
    }

    func testManifestPathTraversalDeletesOutsideDataRoot() throws {
        let root = try Self.rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = root.appendingPathComponent("meetings")
        let outside = root.appendingPathComponent("outside-victim")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("synthetic sentinel".utf8).write(to: outside.appendingPathComponent("sentinel.txt"))
        let storage = SessionStorage(rootURL: dataRoot)
        let session = storage.createDraftSession(captureMode: .imported)
        let realSessionFolder = storage.folderURL(for: session)
        let manifest = realSessionFolder.appendingPathComponent("session.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object["folderName"] = "../outside-victim"
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        let loaded = try XCTUnwrap(storage.loadSessions().first)
        try storage.delete(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: realSessionFolder.path))
        print("BATCH4 traversal: delete of loaded manifest removed sibling sentinel directory, original meeting folder remains")
    }

    func testSymlinkAllowsSessionWriteOutsideDataRoot() throws {
        let root = try Self.rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root.appendingPathComponent("meetings"))
        let outside = root.appendingPathComponent("outside-write")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("meetings/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let session = MeetingSession.makeDraft(createdAt: Date(), captureMode: .imported, folderName: "link")
        try storage.save(session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("session.json").path))
        print("BATCH4 symlink: session.save followed link and wrote outside meetings root")
    }
}
