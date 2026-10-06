import XCTest
import AVFoundation
@testable import MeetingScribe

final class AuditClosureTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-closure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testLegacyDiagnosticMigrationRemovesArbitrarySecretsButPreservesMeetingContent() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = try storage.createDraftSession(captureMode: .imported)
        session.status = .ready
        let meetingText = "正文必须保留 even-if-it-looks-like-a-key"
        session.transcriptText = meetingText
        session.analysis.minutesText = meetingText
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any])
        let secret = "CUSTOM_CREDENTIAL_WITHOUT_KNOWN_PREFIX"
        var analysis = try XCTUnwrap(json["analysis"] as? [String: Any])
        analysis["summaryError"] = "upstream echoed \(secret)"
        analysis["partialNotice"] = "provider reply \(secret)"
        json["analysis"] = analysis
        for key in ["errorMessage", "captureWarning", "lastRegenerationError"] { json[key] = secret }
        let manifest = storage.folderURL(for: session).appendingPathComponent("session.json")
        try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)
        let report = storage.loadSessionsReport()
        let migrated = try XCTUnwrap(report.sessions.first)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(migrated.transcriptText, meetingText)
        XCTAssertEqual(migrated.analysis.minutesText, meetingText)
        XCTAssertFalse(migrated.analysisNotice?.contains(secret) == true)
        XCTAssertFalse(MeetingExporter.markdown(for: migrated).contains(secret))
        XCTAssertFalse(try String(contentsOf: manifest, encoding: .utf8).contains(secret))
        let once = try Data(contentsOf: manifest)
        _ = storage.loadSessionsReport()
        XCTAssertEqual(try Data(contentsOf: manifest), once, "Migration must be idempotent")
    }

    func testDirectUntrustedNoticeNeverLeaksIntoExport() {
        var session = MeetingSession.makeDraft(createdAt: Date(), captureMode: .imported, folderName: "synthetic")
        let secret = "plain-password-no-special-prefix"
        session.analysis.summaryError = secret
        session.analysis.partialNotice = secret
        session.lastRegenerationError = secret
        session.captureWarning = secret
        XCTAssertFalse(session.analysisNotice?.contains(secret) == true)
        XCTAssertFalse(MeetingExporter.markdown(for: session).contains(secret))
        XCTAssertEqual(SafeDiagnostics.summary(SummaryEngineError.requestFailed(401, secret).localizedDescription), SummaryEngineError.requestFailed(401, "").localizedDescription)
    }

    func testFailedImportCopyPreservesExistingDestinationAndManifest() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        let draft = try storage.createDraftSession(captureMode: .imported)
        let destination = storage.folderURL(for: draft).appendingPathComponent("original.wav")
        let bytes = Data("existing audio".utf8)
        try bytes.write(to: destination)
        let manifest = storage.folderURL(for: draft).appendingPathComponent("session.json")
        let originalManifest = try Data(contentsOf: manifest)
        XCTAssertThrowsError(try storage.copyImportedAudio(url: root.appendingPathComponent("missing/original.wav"), into: draft))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try Data(contentsOf: manifest), originalManifest)
    }

    func testSuccessfulImportReplacementIsCompleteAndLeavesNoStagingFile() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root.appendingPathComponent("meetings"))
        let draft = try storage.createDraftSession(captureMode: .imported)
        let source = root.appendingPathComponent("original.wav")
        try Data("first version".utf8).write(to: source)
        let destination = try storage.copyImportedAudio(url: source, into: draft)
        let replacement = Data(repeating: 42, count: 1_024 * 1_024)
        try replacement.write(to: source)
        _ = try storage.copyImportedAudio(url: source, into: draft)
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertEqual(try storage.session(with: draft.id).sourceFileName, "original.wav")
        let files = try FileManager.default.contentsOfDirectory(atPath: storage.folderURL(for: draft).path)
        XCTAssertFalse(files.contains(where: { $0.hasPrefix(".import-") }))
    }

    func testFailedLegacyMigrationStillLoadsSafeMeetingAndReportsFailure() throws {
        let root = try root()
        let storage = SessionStorage(rootURL: root)
        var session = try storage.createDraftSession(captureMode: .imported)
        session.analysis.summaryError = "ARBITRARY_OLD_CREDENTIAL"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let folder = storage.folderURL(for: session)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: root)
        }
        try encoder.encode(session).write(to: folder.appendingPathComponent("session.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let report = storage.loadSessionsReport()
        XCTAssertEqual(report.sessions.count, 1, "A cleanup write failure must not hide a readable meeting")
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertFalse(report.sessions.first?.analysisNotice?.contains("ARBITRARY_OLD_CREDENTIAL") == true)
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("session.json"), encoding: .utf8).contains("ARBITRARY_OLD_CREDENTIAL"), "Must report that old bytes remain when migration cannot commit")
    }

    @MainActor
    private func preferences() -> [(String, Any?)] {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        return keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    private func restore(_ snapshot: [(String, Any?)]) {
        for (key, value) in snapshot {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Lifecycle did not settle")
        throw NSError(domain: "SyntheticFixtureTimeout", code: 1)
    }

    @MainActor
    func testBackgroundStartupGatesNewTasksUntilExistingMeetingsAreLoaded() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = preferences()
        defer { restore(snapshot) }
        let storage = SessionStorage(rootURL: root)
        var old = try storage.createDraftSession(captureMode: .imported)
        old.status = .ready
        old.analysis.summaryModel = "synthetic-test-model"
        old.transcriptText = "Existing synthetic meeting"
        try storage.save(old)
        var creations = 0
        let store = MeetingStore(storage: storage, loadSessionsInBackground: true,
            recordingFactory: { _, _, _ in creations += 1; return SyntheticRecorder() },
            capturePermissions: { (.granted, .granted) })
        XCTAssertTrue(store.isLoadingSessions)
        store.startRecording()
        store.importAudio(url: root.appendingPathComponent("unused.wav"))
        XCTAssertEqual(creations, 0)
        try await waitFor { !store.isLoadingSessions }
        XCTAssertEqual(store.sessions.map(\.id), [old.id])
        XCTAssertEqual(store.selectedSession?.transcriptText, old.transcriptText)
        XCTAssertEqual(storage.loadSessions().count, 1)
    }

    @MainActor
    func testPreparationIsExclusiveAndCancellationCannotBecomeLateRecording() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = preferences()
        defer { restore(snapshot) }
        let recorder = SyntheticRecorder()
        let storage = SessionStorage(rootURL: root)
        var creations = 0
        let store = MeetingStore(storage: storage, recordingFactory: { _, _, _ in creations += 1; return recorder }, capturePermissions: { (.granted, .granted) })
        store.startRecording()
        store.startRecording()
        store.importAudio(url: root.appendingPathComponent("unused.wav"))
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertTrue(store.isPreparingRecording)
        try await waitFor { recorder.startContinuation != nil }
        store.deleteSession(try XCTUnwrap(store.sessions.first))
        XCTAssertEqual(store.sessions.count, 1)
        store.stopRecording()
        recorder.completeStart()
        try await waitFor { !store.isPreparingRecording }
        XCTAssertFalse(store.isRecording)
        XCTAssertFalse(store.isProcessing)
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(storage.loadSessions().first?.status, .failed)
    }

    @MainActor
    func testFailureDuringPreparationAndOldCallbackCannotCorruptNextRecording() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = preferences()
        defer { restore(snapshot) }
        let first = SyntheticRecorder()
        let second = SyntheticRecorder()
        var count = 0
        let store = MeetingStore(storage: SessionStorage(rootURL: root), recordingFactory: { _, _, _ in
            count += 1
            return count == 1 ? first : second
        }, capturePermissions: { (.granted, .denied) })
        store.startRecording()
        try await waitFor { first.startContinuation != nil }
        let lateCallback = first.onFailure
        first.onFailure?("synthetic device failure")
        first.completeStart()
        try await waitFor { !store.isPreparingRecording }
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(first.stopCount, 1)
        store.startRecording()
        try await waitFor { second.startContinuation != nil }
        second.completeStart()
        try await waitFor { store.isRecording }
        let secondID = store.selectedSessionID
        lateCallback?("old failure")
        XCTAssertTrue(store.isRecording)
        XCTAssertEqual(store.selectedSessionID, secondID)
        second.onFailure?("synthetic stream failure")
        second.onFailure?("duplicate failure")
        try await waitFor { !store.isProcessing }
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertEqual(store.selectedSession?.status, .failed)
    }

    @MainActor
    func testStopReleasesRecordingEvenWhenTerminalStateCannotBeSaved() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = preferences()
        defer { restore(snapshot) }
        let recorder = SyntheticRecorder()
        let storage = SessionStorage(rootURL: root)
        let store = MeetingStore(storage: storage, recordingFactory: { _, _, _ in recorder }, capturePermissions: { (.granted, .granted) })
        store.startRecording()
        try await waitFor { recorder.startContinuation != nil }
        recorder.completeStart()
        try await waitFor { store.isRecording }
        let session = try XCTUnwrap(store.selectedSession)
        let manifest = storage.folderURL(for: session).appendingPathComponent("session.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        store.stopRecording()
        try await waitFor { !store.isProcessing }
        XCTAssertEqual(recorder.stopCount, 1, "Disk failure must not leave capture running")
        XCTAssertFalse(store.isRecording)
        XCTAssertNotNil(store.storageWriteNotice)
        XCTAssertTrue(store.errorMessage?.contains("未能保存") == true)
    }

    @MainActor
    func testManifestFailureDuringTranscriptionCannotReportSuccess() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = preferences()
        defer { restore(snapshot) }
        let storage = SessionStorage(rootURL: root.appendingPathComponent("meetings"))
        var session = try storage.createDraftSession(captureMode: .imported)
        session.status = .failed
        session.sourceFileName = "source.wav"
        let folder = storage.folderURL(for: session)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0.05, count: 16_000)
        do { let audio = try AVAudioFile(forWriting: folder.appendingPathComponent("source.wav"), settings: format.settings); try audio.write(from: buffer) }
        try storage.save(session)
        let cli = root.appendingPathComponent("synthetic-cli")
        try """
        #!/usr/bin/env python3
        import sys, json
        from pathlib import Path
        args = sys.argv[1:]
        prefix = Path(args[args.index('-of') + 1])
        manifest = prefix.parent.parent / 'session.json'
        manifest.rename(manifest.with_name('previous-manifest.json'))
        manifest.mkdir()
        Path(str(prefix) + '.json').write_text(json.dumps({'transcription': [{'offsets': {'from': 0, 'to': 1000}, 'text': 'Synthetic newly transcribed text', 'tokens': []}]}))
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let model = root.appendingPathComponent("model.bin")
        try Data("synthetic-model".utf8).write(to: model)
        let store = MeetingStore(storage: storage)
        store.whisperCLIPath = cli.path
        store.whisperModelPath = model.path
        store.summarySettings = .default
        store.retryProcessing(session)
        try await waitFor { !store.isProcessing }
        XCTAssertEqual(store.selectedSession?.status, .failed)
        XCTAssertNotNil(store.storageWriteNotice)
        XCTAssertNotEqual(store.statusText, "已完成")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("previous-manifest.json").path))
    }
}

@MainActor
private final class SyntheticRecorder: RecordingSession {
    var levels: (local: Double, remote: Double) { (0, 0) }
    var onFailure: ((String) -> Void)?
    var startContinuation: CheckedContinuation<Void, Error>?
    var stopCount = 0
    func start() async throws {
        try await withCheckedThrowingContinuation { startContinuation = $0 }
    }
    func completeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
    func stop() async throws -> MixedRecordingResult {
        stopCount += 1
        throw PipelineError.failedToStopCapture
    }
}
