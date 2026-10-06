import Foundation

struct SummaryRequestContext: Sendable {
    let settings: SummaryModelSettings
    let apiKey: String?
    let glossary: Glossary
}

/// Pure transcript preparation and local fallback never run on MainActor.
actor MeetingAnalysisWorker {
    func applyingTerminology(_ segments: [TranscriptSegment], table: [String: String]) throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let result = TranscriptCleaner.applyingTerminology(segments, table: table)
        try Task.checkCancellation()
        return result
    }

    func fallback(from segments: [TranscriptSegment]) throws -> MeetingAnalysis {
        try Task.checkCancellation()
        let result = MeetingAnalysisBuilder.build(from: segments)
        try Task.checkCancellation()
        return result
    }
}
