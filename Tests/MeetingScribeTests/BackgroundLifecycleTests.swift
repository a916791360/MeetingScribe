import AppKit
import Foundation
import XCTest
@testable import MeetingScribe

private actor LifecycleGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class LifecycleFailureRecorder: RecordingSession {
    var levels: (local: Double, remote: Double) { (0, 0) }
    var onFailure: ((String) -> Void)?
    private(set) var stops = 0
    func start() async throws { throw PipelineError.failedToStartCapture }
    func stop() async throws -> MixedRecordingResult { stops += 1; throw PipelineError.failedToStopCapture }
}

final class BackgroundLifecycleTests: XCTestCase {
    @MainActor
    private func fixture(_ body: (SessionStorage) async throws -> Void) async throws {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let prefs = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in prefs { if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-background-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(SessionStorage(rootURL: root))
    }

    @MainActor
    private func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<600 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NSError(domain: "LifecycleGateTimeout", code: 1)
    }

    @MainActor
    func testCancelledDraftPreparationCreatesNoOrphanAndBlocksQuitAndOverlap() async throws {
        try await fixture { storage in
            let gate = LifecycleGate()
            var creations = 0
            let repository = SessionRepository(storage: storage, beforeMutation: { await gate.wait() })
            let store = MeetingStore(storage: storage, repository: repository, recordingFactory: { _, _, _ in creations += 1; return LifecycleFailureRecorder() }, capturePermissions: { (.granted, .granted) })
            let delegate = MeetingApplicationDelegate(); delegate.store = store
            store.startRecording()
            XCTAssertTrue(store.isPreparingRecording)
            store.startRecording(); store.importAudio(url: storage.dataDirectoryURL.appendingPathComponent("missing.wav"))
            try await waitFor { await gate.entered }
            XCTAssertEqual(creations, 0)
            XCTAssertTrue(storage.loadSessions().isEmpty)
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
            store.stopRecording()
            XCTAssertTrue(store.isPreparingRecording)
            await gate.release()
            try await waitFor { !store.isPreparingRecording }
            XCTAssertTrue(storage.loadSessions().isEmpty)
            XCTAssertFalse(store.isRecording)
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        }
    }

    @MainActor
    func testImportCancellationBeforeDraftCommitLeavesNoOrphan() async throws {
        try await fixture { storage in
            let gate = LifecycleGate()
            let repository = SessionRepository(storage: storage, beforeMutation: { await gate.wait() })
            let store = MeetingStore(storage: storage, repository: repository)
            store.captureBlockedNotice = "合成录音权限提示"
            store.importAudio(url: storage.dataDirectoryURL.appendingPathComponent("missing.wav"))
            XCTAssertTrue(store.isProcessing)
            XCTAssertNil(store.captureBlockedNotice, "Import does not require capture permissions")
            try await waitFor { await gate.entered }
            store.cancelProcessing()
            XCTAssertTrue(store.isProcessing)
            await gate.release()
            try await waitFor { !store.isProcessing }
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertTrue(storage.loadSessions().isEmpty)
            XCTAssertNil(store.errorMessage)
        }
    }

    @MainActor
    func testCancelledRetryBeforeResetPreservesManifestExactly() async throws {
        try await fixture { storage in
            var session = try storage.createDraftSession(captureMode: .imported)
            session.status = .ready
            session.transcriptText = "合成旧内容"
            session.processingNextOffset = 600
            session.analysis.minutesText = "合成旧纪要"
            try storage.save(session)
            try Data([1, 2, 3]).write(to: storage.sourceURL(for: session, preferredFileName: session.sourceFileName))
            let manifest = storage.folderURL(for: session).appendingPathComponent("session.json")
            let gate = LifecycleGate()
            let store = MeetingStore(storage: storage, repository: SessionRepository(storage: storage, beforeMutation: { await gate.wait() }))
            let before = try Data(contentsOf: manifest) // Startup migration is outside the retry under test.
            store.retryProcessing(session)
            XCTAssertTrue(store.isProcessing)
            try await waitFor { await gate.entered }
            store.cancelProcessing()
            await gate.release()
            try await waitFor { !store.isProcessing }
            XCTAssertEqual(try Data(contentsOf: manifest), before)
            XCTAssertEqual(store.sessions.first?.transcriptText, "合成旧内容")
        }
    }

    @MainActor
    func testCancelledRecoveryWaitsBeforeReleasingOperationSlotAndPreservesRename() async throws {
        try await fixture { storage in
            let recovery = LifecycleGate()
            let recorder = LifecycleFailureRecorder()
            let store = MeetingStore(storage: storage, repository: SessionRepository(storage: storage, beforeRecovery: { await recovery.wait() }), recordingFactory: { _, _, _ in recorder }, capturePermissions: { (.granted, .granted) })
            store.startRecording()
            try await waitFor { await recovery.entered }
            let draft = try XCTUnwrap(store.selectedSession)
            XCTAssertEqual(recorder.stops, 1)
            store.stopRecording() // Cancel the owner while recovery is awaiting disk work.
            store.startRecording(); store.importAudio(url: storage.dataDirectoryURL.appendingPathComponent("missing.wav"))
            XCTAssertTrue(store.isPreparingRecording)
            XCTAssertEqual(store.sessions.count, 1)
            try storage.update(draft.id) { $0.title = "合成并发名称"; $0.titleManuallyEdited = true }
            await recovery.release()
            try await waitFor { !store.isPreparingRecording }
            let saved = try storage.session(with: draft.id)
            XCTAssertEqual(saved.status, .failed)
            XCTAssertEqual(saved.title, "合成并发名称")
            XCTAssertEqual(store.selectedSession?.title, saved.title)
        }
    }

    @MainActor
    func testActiveCaptureAndProcessingRefuseNormalQuit() async throws {
        try await fixture { storage in
            let store = MeetingStore(storage: storage)
            let delegate = MeetingApplicationDelegate(); delegate.store = store
            store.isRecording = true
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
            XCTAssertTrue(store.errorMessage?.contains("停止录音") == true)
            store.isRecording = false; store.isProcessing = true
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
            XCTAssertTrue(store.errorMessage?.contains("取消处理") == true)
            store.isProcessing = false
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        }
    }
}
