import Foundation

/// Pipeline persistence runs outside MainActor. Every mutation rereads and writes
/// under one storage lock, so a background checkpoint cannot overwrite a rename.
actor SessionRepository {
    private let storage: SessionStorage
    private let beforeMutation: @Sendable () async throws -> Void

    init(storage: SessionStorage, beforeMutation: @escaping @Sendable () async throws -> Void = {}) {
        self.storage = storage
        self.beforeMutation = beforeMutation
    }

    func session(with id: UUID) throws -> MeetingSession {
        try Task.checkCancellation()
        return try storage.session(with: id)
    }

    func update(_ id: UUID, _ mutation: @Sendable (inout MeetingSession) throws -> Void) async throws -> MeetingSession {
        try Task.checkCancellation()
        try await beforeMutation()
        try Task.checkCancellation()
        return try storage.update(id, mutation)
    }

    struct TranscriptEditResult: Sendable {
        let session: MeetingSession?
        let outcome: TranscriptEditor.Outcome
    }

    private struct UnchangedEdit: Error {
        let outcome: TranscriptEditor.Outcome
    }

    func editTranscript(sessionID: UUID, segmentID: UUID, text: String) async throws -> TranscriptEditResult {
        try Task.checkCancellation()
        try await beforeMutation()
        try Task.checkCancellation()
        do {
            let updated = try storage.update(sessionID) { session in
                let outcome = TranscriptEditor.apply(text: text, to: session.transcriptSegments, segmentID: segmentID)
                guard case let .saved(segments) = outcome else { throw UnchangedEdit(outcome: outcome) }
                session.transcriptSegments = segments
                session.transcriptText = segments.map(\.text).joined(separator: "\n")
                session.transcriptEditedAt = Date()
                session.analysisStale = true
                session.updatedAt = Date()
            }
            return TranscriptEditResult(session: updated, outcome: .saved(updated.transcriptSegments))
        } catch let unchanged as UnchangedEdit {
            return TranscriptEditResult(session: nil, outcome: unchanged.outcome)
        }
    }

    func delete(_ session: MeetingSession) throws {
        try Task.checkCancellation()
        try storage.delete(session)
    }
}
