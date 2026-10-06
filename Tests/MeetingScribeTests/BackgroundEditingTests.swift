import Foundation
import AppKit
import XCTest
@testable import MeetingScribe

private actor EditGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class FailingEditReviewRecorder: RecordingSession {
    let gate: EditGate
    init(gate: EditGate) { self.gate = gate }
    var levels: (local: Double, remote: Double) { (0, 0) }
    var onFailure: ((String) -> Void)?
    func start() async throws { await gate.wait(); throw PipelineError.transcriptionFailed("合成启动故障") }
    func stop() async throws -> MixedRecordingResult { throw PipelineError.failedToStopCapture }
}

final class BackgroundEditingTests: XCTestCase {
    @MainActor
    private func fixture(_ body: (SessionStorage, MeetingSession, MeetingStore, EditGate) async throws -> Void) async throws {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let prefs = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in prefs { if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-background-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = try storage.createDraftSession(captureMode: .imported)
        session.status = .ready
        session.transcriptSegments = (0..<6).map { i in
            TranscriptSegment(start: Double(i*10), end: Double(i*10+10), text: "合成第\(i)段：审查甲下周提交报价，审查乙验证接口。这是充足的隔离测试材料，不含真实会议。", confidence: 0.9)
        }
        session.transcriptText = session.transcriptSegments.map(\.text).joined(separator: "\n")
        session.analysis.minutesText = "合成旧纪要"
        session.analysis.summaryModel = "合成旧模型"
        try storage.save(session)
        let gate = EditGate()
        let repository = SessionRepository(storage: storage, beforeMutation: { await gate.wait() })
        let store = MeetingStore(storage: storage, repository: repository, recordingFactory: { _, _, _ in FailingEditReviewRecorder(gate: gate) }, capturePermissions: { (.granted, .granted) })
        try await body(storage, session, store, gate)
    }

    @MainActor
    private func waitForGate(_ gate: EditGate) async throws {
        for _ in 0..<600 { if await gate.entered { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Mutation did not reach isolated gate")
    }

    @MainActor
    func testPendingEditKeepsDraftAndBlocksConflictingWork() async throws {
        try await fixture { storage, session, store, gate in
            let segment = session.transcriptSegments[0]
            store.transcriptDrafts[segment.id] = "人工合成校正"
            let task = Task { await store.updateTranscriptSegment(sessionID: session.id, segmentID: segment.id, text: "人工合成校正") }
            try await waitForGate(gate)
            XCTAssertTrue(store.isSavingSessions)
            let delegate = MeetingApplicationDelegate()
            delegate.store = store
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
            XCTAssertEqual(store.transcriptDrafts[segment.id], "人工合成校正")
            let overlapping = await store.updateTranscriptSegment(sessionID: session.id, segmentID: segment.id, text: "不能覆盖的重复提交")
            guard case .rejected = overlapping else { return XCTFail("Duplicate save must be rejected") }
            let renamed = await store.renameSession(session, to: "冲突名称")
            XCTAssertFalse(renamed)
            store.deleteSession(session)
            store.reloadSessions()
            store.startRecording()
            store.importAudio(url: storage.dataDirectoryURL.appendingPathComponent("missing.wav"))
            store.regenerateSummary(for: session)
            XCTAssertFalse(store.isDeletingSessions)
            XCTAssertFalse(store.isLoadingSessions)
            XCTAssertFalse(store.isProcessing)
            XCTAssertFalse(store.isPreparingRecording)
            XCTAssertEqual(store.sessions.count, 1)
            await gate.release()
            guard case .saved = await task.value else { return XCTFail("Original edit must save") }
            XCTAssertFalse(store.isSavingSessions)
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
            let saved = try storage.session(with: session.id)
            XCTAssertEqual(saved.transcriptSegments[0].text, "人工合成校正")
            XCTAssertEqual(saved.analysis.minutesText, "合成旧纪要")
            XCTAssertEqual(saved.analysisStale, true)
        }
    }

    @MainActor
    func testEditTransactionPreservesLatestConcurrentName() async throws {
        try await fixture { storage, session, store, gate in
            let task = Task { await store.updateTranscriptSegment(sessionID: session.id, segmentID: session.transcriptSegments[0].id, text: "人工校正合成内容") }
            try await waitForGate(gate)
            try storage.update(session.id) { $0.title = "后台最新人工名称"; $0.titleManuallyEdited = true }
            await gate.release()
            guard case .saved = await task.value else { return XCTFail("Edit must succeed") }
            XCTAssertEqual(store.sessions.first?.title, "后台最新人工名称")
            XCTAssertEqual(try storage.session(with: session.id).title, "后台最新人工名称")
        }
    }

    @MainActor
    func testCancelledSaveBeforeCommitKeepsOldFileAndDraft() async throws {
        try await fixture { storage, session, store, gate in
            let segment = session.transcriptSegments[0]
            store.transcriptDrafts[segment.id] = "取消前的合成草稿"
            let file = storage.folderURL(for: session).appendingPathComponent("session.json")
            let before = try Data(contentsOf: file)
            let task = Task { await store.updateTranscriptSegment(sessionID: session.id, segmentID: segment.id, text: "取消前的合成草稿") }
            try await waitForGate(gate)
            task.cancel()
            await gate.release()
            guard case .rejected = await task.value else { return XCTFail("Cancelled save must fail before commit") }
            XCTAssertFalse(store.isSavingSessions)
            XCTAssertEqual(try Data(contentsOf: file), before)
            XCTAssertEqual(store.transcriptDrafts[segment.id], "取消前的合成草稿")
        }
    }

    @MainActor
    func testWriteFailureKeepsDraftAndReleasesSaveGate() async throws {
        try await fixture { storage, session, store, gate in
            let segment = session.transcriptSegments[0]
            store.transcriptDrafts[segment.id] = "待重试合成草稿"
            let task = Task { await store.updateTranscriptSegment(sessionID: session.id, segmentID: segment.id, text: "待重试合成草稿") }
            try await waitForGate(gate)
            // A non-file manifest simulates a read/write failure on an isolated root.
            let manifest = storage.folderURL(for: session).appendingPathComponent("session.json")
            let data = try Data(contentsOf: manifest)
            try FileManager.default.removeItem(at: manifest)
            try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            await gate.release()
            guard case .rejected = await task.value else { return XCTFail("Disk failure must reject edit") }
            XCTAssertFalse(store.isSavingSessions)
            XCTAssertEqual(store.transcriptDrafts[segment.id], "待重试合成草稿")
            XCTAssertEqual(store.sessions.first?.transcriptSegments[0].text, segment.text)
            try FileManager.default.removeItem(at: manifest)
            try data.write(to: manifest)
        }
    }

    func testUnchangedOrRejectedTransactionDoesNotRewriteManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-edit-noop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = try storage.createDraftSession(captureMode: .imported)
        session.transcriptSegments = [TranscriptSegment(start: 0, end: 2, text: "合成原句", confidence: 1)]
        try storage.save(session)
        let file = storage.folderURL(for: session).appendingPathComponent("session.json")
        let before = try Data(contentsOf: file)
        let repository = SessionRepository(storage: storage)
        let unchanged = try await repository.editTranscript(sessionID: session.id, segmentID: session.transcriptSegments[0].id, text: " 合成原句 ")
        XCTAssertEqual(unchanged.outcome, .unchanged)
        let rejected = try await repository.editTranscript(sessionID: session.id, segmentID: session.transcriptSegments[0].id, text: " ")
        guard case .rejected = rejected.outcome else { return XCTFail("Blank edit must be rejected") }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    @MainActor
    func testRecordingFailurePreservesUnpublishedRename() async throws {
        try await fixture { storage, _, _, gate in
            let store = MeetingStore(storage: storage, recordingFactory: { _, _, _ in FailingEditReviewRecorder(gate: gate) }, capturePermissions: { (.granted, .granted) })
            store.startRecording()
            try await waitForGate(gate)
            let draft = try XCTUnwrap(store.sessions.first)
            try storage.update(draft.id) { $0.title = "未发布但已保存的人工名称"; $0.titleManuallyEdited = true }
            await gate.release()
            for _ in 0..<600 where store.isPreparingRecording { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(store.isPreparingRecording)
            let saved = try storage.session(with: draft.id)
            XCTAssertEqual(saved.title, "未发布但已保存的人工名称")
            XCTAssertEqual(saved.status, .failed)
            XCTAssertEqual(store.sessions.first(where: { $0.id == draft.id })?.title, saved.title)
        }
    }
}
