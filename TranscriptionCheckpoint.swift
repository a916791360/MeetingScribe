import CryptoKit
import Foundation

/// Raw per-source results, separate from any previously edited visible transcript.
/// Optional on MeetingSession so older manifests remain readable.
struct DualTrackCheckpoint: Codable, Hashable, Sendable {
    var environment: TranscriptionEnvironment
    var local: TrackTranscriptionCheckpoint?
    var remote: TrackTranscriptionCheckpoint?

    subscript(speaker: TranscriptSpeaker) -> TrackTranscriptionCheckpoint? {
        get { speaker == .local ? local : remote }
        set {
            if speaker == .local { local = newValue }
            else { remote = newValue }
        }
    }

    var completedChunks: Int { (local?.completedChunks ?? 0) + (remote?.completedChunks ?? 0) }
    var totalChunks: Int { (local?.totalChunks ?? 0) + (remote?.totalChunks ?? 0) }
    var segments: [TranscriptSegment] {
        ((local?.segments ?? []) + (remote?.segments ?? [])).sorted { $0.start < $1.start }
    }
}

struct SingleTrackCheckpoint: Codable, Hashable, Sendable {
    var environment: TranscriptionEnvironment
    var track: TrackTranscriptionCheckpoint
}

struct TranscriptionEnvironment: Codable, Hashable, Sendable {
    let cliSHA256: String
    let modelSHA256: String
    let initialPrompt: String
    let chunkSeconds: TimeInterval
    let overlapSeconds: TimeInterval
    // Changing ownership or checkpoint semantics must invalidate old raw results.
    var formatVersion: Int = 1
}

struct TrackTranscriptionCheckpoint: Codable, Hashable, Sendable {
    let sourceName: String
    let sourceSHA256: String
    let duration: TimeInterval
    let totalChunks: Int
    var completedChunks: Int = 0
    var segments: [TranscriptSegment] = []

    func canResume(sourceName: String, sha256: String, duration: TimeInterval,
                   totalChunks: Int, speaker: TranscriptSpeaker?) -> Bool {
        self.sourceName == sourceName && sourceSHA256 == sha256 && self.duration == duration &&
            self.totalChunks == totalChunks && completedChunks >= 0 && completedChunks <= totalChunks &&
            segments.allSatisfy { $0.speaker == speaker && $0.start.isFinite && $0.end.isFinite }
    }
}

/// CPU/file-only work runs on this actor's executor, never on MainActor.
actor AudioTranscriptionWorker {
    func clean(_ segments: [TranscriptSegment], options: TranscriptCleaner.Options) throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let result = TranscriptCleaner.clean(segments, options: options)
        try Task.checkCancellation()
        return result
    }

    func duration(for url: URL) throws -> TimeInterval {
        try Task.checkCancellation()
        return try AudioDurationReader().duration(for: url)
    }

    func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func isAudible(_ url: URL, threshold: Float) throws -> Bool {
        try Task.checkCancellation()
        do { return try AudioLevelProbe().hasAudibleSignal(at: url, threshold: threshold) }
        catch is CancellationError { throw CancellationError() }
        catch { return true } // Read failure is not evidence of silence.
    }
}
