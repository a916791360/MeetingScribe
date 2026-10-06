import Foundation
import XCTest
@testable import MeetingScribe

private actor SummaryCompletionGate {
    private(set) var calls = 0
    private(set) var models: [String] = []
    private(set) var texts: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func analyze(segments: [TranscriptSegment] = [], settings: SummaryModelSettings? = nil) async -> MeetingAnalysis {
        calls += 1
        models.append(settings?.modelName ?? "")
        texts.append(segments.map(\.text).joined(separator: "\n"))
        if !released { await withCheckedContinuation { continuations.append($0) } }
        var result = MeetingAnalysis.empty
        result.minutesText = "合成新纪要"
        result.summaryModel = "合成模型"
        return result
    }

    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

final class SummaryLifecycleTests: XCTestCase {
    @MainActor
    private func exerciseCancellation(deleteAfterCancel: Bool) async throws {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let snapshot = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in snapshot {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-summary-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = try storage.createDraftSession(captureMode: .imported)
        session.status = .ready
        session.transcriptSegments = (0..<6).map { i in
            TranscriptSegment(start: Double(i * 10), end: Double(i * 10 + 10), text: "合成会议第\(i)段：审查甲安排报价并在下周提交预算，审查乙负责接口验收。这是隔离的生命周期测试材料，不含任何真实会议或客户信息。", confidence: 1)
        }
        session.transcriptText = session.transcriptSegments.map(\.text).joined(separator: "\n")
        session.analysis.minutesText = "合成旧纪要"
        session.analysis.summaryModel = "合成旧模型"
        try storage.save(session)
        let gate = SummaryCompletionGate()
        let store = MeetingStore(storage: storage, summaryAnalyzer: { _, _, _, _ in await gate.analyze() })
        store.summarySettings = .default
        store.glossaryText = ""
        store.regenerateSummary(for: session)
        for _ in 0..<600 {
            if await gate.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let entered = await gate.calls
        XCTAssertEqual(entered, 1)
        store.cancelProcessing()
        XCTAssertTrue(store.isProcessing, "Cancellation must keep the task slot until the old task exits")
        if deleteAfterCancel {
            store.deleteSession(session)
            XCTAssertTrue(store.isDeletingSessions)
            store.importAudio(url: root.appendingPathComponent("nonexistent.wav"))
            XCTAssertEqual(store.sessions.count, 1, "No new import during pending deletion")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.folderURL(for: session).path), "Deletion must wait for the active task")
        store.regenerateSummary(for: session)
        let overlapping = await gate.calls
        XCTAssertEqual(overlapping, 1)
        await gate.release()
        for _ in 0..<600 {
            if !store.isProcessing && (!deleteAfterCancel || store.sessions.isEmpty) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isProcessing)
        XCTAssertFalse(store.isDeletingSessions)
        if deleteAfterCancel {
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.folderURL(for: session).path))
        } else {
            XCTAssertEqual(try storage.session(with: session.id).analysis.minutesText, "合成旧纪要")
            store.regenerateSummary(for: session)
            for _ in 0..<600 where store.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(try storage.session(with: session.id).analysis.minutesText, "合成新纪要")
            let finalCalls = await gate.calls
            XCTAssertEqual(finalCalls, 2)
        }
    }

    @MainActor
    func testSummaryCancellationRetainsTaskSlotUntilCompletion() async throws {
        try await exerciseCancellation(deleteAfterCancel: false)
    }

    @MainActor
    func testDeletionAfterSummaryCancellationWaitsForCompletion() async throws {
        try await exerciseCancellation(deleteAfterCancel: true)
    }

    @MainActor
    func testSummaryCompletionPreservesRenameAndRequestSnapshot() async throws {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let snapshot = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in snapshot {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-summary-snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = try storage.createDraftSession(captureMode: .imported)
        session.status = .ready
        session.transcriptSegments = (0..<6).map { i in
            TranscriptSegment(start: Double(i * 10), end: Double(i * 10 + 10), text: "合成第\(i)段：审查甲下周提交报价材料，审查乙负责验证接口。这是隔离的模拟会议，用来验证术语校正与重新整理的配置快照。", confidence: 1)
        }
        session.transcriptText = session.transcriptSegments.map(\.text).joined(separator: "\n")
        try storage.save(session)
        let gate = SummaryCompletionGate()
        let store = MeetingStore(storage: storage, summaryAnalyzer: { segments, settings, _, _ in
            await gate.analyze(segments: segments, settings: settings)
        })
        store.summarySettings = .default
        store.summarySettings.modelName = "initial-model"
        store.glossaryText = "审查初始人, 审查甲"
        store.regenerateSummary(for: session)
        // Change settings before the async task starts. The tap's snapshot must win.
        store.summarySettings.modelName = "changed-model"
        store.glossaryText = "审查变更人, 审查甲"
        for _ in 0..<600 {
            if await gate.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.renameSession(session, to: "人工指定名称")
        await gate.release()
        for _ in 0..<600 where store.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isProcessing)
        let models = await gate.models
        let texts = await gate.texts
        XCTAssertEqual(models, ["initial-model"])
        XCTAssertTrue(texts.first?.contains("审查初始人") == true)
        XCTAssertFalse(texts.first?.contains("审查变更人") == true)
        let saved = try storage.session(with: session.id)
        XCTAssertEqual(saved.title, "人工指定名称")
        XCTAssertEqual(saved.analysis.minutesText, "合成新纪要")
        XCTAssertTrue(saved.transcriptText.contains("审查初始人"))
    }

    @MainActor
    func testFailedBackgroundDeletionKeepsMeetingAndReleasesGate() async throws {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let snapshot = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in snapshot {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-delete-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        let session = try storage.createDraftSession(captureMode: .imported)
        let store = MeetingStore(storage: storage)
        var invalid = session
        invalid.folderName = "../outside"
        store.deleteSession(invalid)
        XCTAssertTrue(store.isDeletingSessions)
        for _ in 0..<600 where store.isDeletingSessions { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isDeletingSessions)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertNoThrow(try storage.session(with: session.id))
    }
}
