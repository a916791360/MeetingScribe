import Foundation

/// Pipeline persistence runs outside MainActor. Every mutation rereads and writes
/// under one storage lock, so a background checkpoint cannot overwrite a rename.
actor SessionRepository {
    private let storage: SessionStorage

    init(storage: SessionStorage) { self.storage = storage }

    func session(with id: UUID) throws -> MeetingSession {
        try Task.checkCancellation()
        return try storage.session(with: id)
    }

    func update(_ id: UUID, _ mutation: @Sendable (inout MeetingSession) throws -> Void) throws -> MeetingSession {
        try Task.checkCancellation()
        return try storage.update(id, mutation)
    }
}
