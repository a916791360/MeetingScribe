import Foundation
import XCTest
@testable import MeetingScribe

final class CheckpointRepositoryTests: XCTestCase {
    func testCheckpointRejectsChangedSourceAndInvalidCounters() {
        let segment = TranscriptSegment(start: 0, end: 1, text: "Synthetic", confidence: 0.9, speaker: .local)
        var checkpoint = TrackTranscriptionCheckpoint(sourceName: "local.wav", sourceSHA256: "original", duration: 601, totalChunks: 2, completedChunks: 1, segments: [segment])
        XCTAssertTrue(checkpoint.canResume(sourceName: "local.wav", sha256: "original", duration: 601, totalChunks: 2, speaker: .local))
        XCTAssertFalse(checkpoint.canResume(sourceName: "local.wav", sha256: "changed", duration: 601, totalChunks: 2, speaker: .local))
        XCTAssertFalse(checkpoint.canResume(sourceName: "remote.wav", sha256: "original", duration: 601, totalChunks: 2, speaker: .local))
        XCTAssertFalse(checkpoint.canResume(sourceName: "local.wav", sha256: "original", duration: 601, totalChunks: 2, speaker: .remote))
        for invalid in [-1, 3] {
            checkpoint.completedChunks = invalid
            XCTAssertFalse(checkpoint.canResume(sourceName: "local.wav", sha256: "original", duration: 601, totalChunks: 2, speaker: .local))
        }
    }

    func testEnvironmentChangesInvalidateResume() {
        let original = TranscriptionEnvironment(cliSHA256: "engine", modelSHA256: "model", initialPrompt: "terms", chunkSeconds: 600, overlapSeconds: 2)
        XCTAssertNotEqual(original, TranscriptionEnvironment(cliSHA256: "new", modelSHA256: "model", initialPrompt: "terms", chunkSeconds: 600, overlapSeconds: 2))
        XCTAssertNotEqual(original, TranscriptionEnvironment(cliSHA256: "engine", modelSHA256: "new", initialPrompt: "terms", chunkSeconds: 600, overlapSeconds: 2))
        XCTAssertNotEqual(original, TranscriptionEnvironment(cliSHA256: "engine", modelSHA256: "model", initialPrompt: "changed", chunkSeconds: 600, overlapSeconds: 2))
        XCTAssertNotEqual(original, TranscriptionEnvironment(cliSHA256: "engine", modelSHA256: "model", initialPrompt: "terms", chunkSeconds: 300, overlapSeconds: 2))
    }

    @MainActor
    func testBackgroundTransactionPreservesConcurrentUnrelatedEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-repository-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        let session = try storage.createDraftSession(captureMode: .imported)
        let repository = SessionRepository(storage: storage)
        let background = Task {
            try await repository.update(session.id) { current in
                XCTAssertFalse(Thread.isMainThread, "Pipeline JSON work must leave MainActor")
                current.processingCompletedChunks = 2
            }
        }
        try storage.update(session.id) { current in
            current.title = "人工会议名称"
            current.titleManuallyEdited = true
        }
        _ = try await background.value
        let saved = try storage.session(with: session.id)
        XCTAssertEqual(saved.title, "人工会议名称")
        XCTAssertEqual(saved.processingCompletedChunks, 2)
        XCTAssertTrue(saved.titleManuallyEdited == true)
        XCTAssertEqual(MeetingAnalysisBuilder.title(for: saved, segments: []), "人工会议名称")
    }

    func testTransactionCannotChangeManifestIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-repository-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        let session = try storage.createDraftSession(captureMode: .imported)
        let baseline = try storage.session(with: session.id)
        XCTAssertThrowsError(try storage.update(session.id) { $0.id = UUID() })
        XCTAssertThrowsError(try storage.update(session.id) { $0.folderName = "elsewhere" })
        XCTAssertEqual(try storage.session(with: session.id), baseline)
    }
}
