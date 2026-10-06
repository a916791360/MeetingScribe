import Foundation

@MainActor
final class ResponsivenessProbe {
    var gaps: [Double] = []

    func run(_ operation: @MainActor () async throws -> Void) async throws -> [String: Double] {
        gaps = []
        let ticker = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime
                gaps.append((now - previous) * 1000)
                previous = now
            }
        }
        defer { ticker.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        var durations: [Double] = []
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            try await operation()
            durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        try await Task.sleep(for: .milliseconds(20))
        ticker.cancel()
        await ticker.value
        return ["mean_transaction_ms": durations.reduce(0, +) / Double(durations.count),
                "max_main_actor_tick_gap_ms": gaps.max() ?? 0,
                "main_actor_ticks": Double(gaps.count)]
    }
}

@main
struct ReviewPersistenceBenchmark {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-persistence-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        let repository = SessionRepository(storage: storage)
        let probe = ResponsivenessProbe()
        var measurements: [[String: Any]] = []
        for count in [1_000, 10_000, 50_000] {
            let session = try await Task.detached {
                var session = try storage.createDraftSession(captureMode: .imported)
                session.transcriptSegments = (0..<count).map { index in
                    TranscriptSegment(start: Double(index), end: Double(index + 1), text: "合成性能材料第\(index)段：报价安排与接口验收由指定成员负责。本测试完全隔离，不读取真实会议。", confidence: 0.9)
                }
                session.transcriptText = session.transcriptSegments.map(\.text).joined(separator: "\n")
                try storage.save(session)
                return session
            }.value
            let synchronous = try await probe.run {
                try storage.update(session.id) { $0.processingCompletedChunks = ($0.processingCompletedChunks ?? 0) + 1 }
            }
            let background = try await probe.run {
                _ = try await repository.update(session.id) { $0.processingCompletedChunks = ($0.processingCompletedChunks ?? 0) + 1 }
            }
            let manifest = storage.folderURL(for: session).appendingPathComponent("session.json")
            measurements.append(["segments": count,
                                 "manifest_bytes": try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                                 "synchronous_main_actor": synchronous,
                                 "background_repository": background])
        }
        let output: [String: Any] = ["schema": 1, "synthetic_only": true,
                                   "note": "Three transactions per mode on this machine. Tick gaps measure MainActor scheduling, not UI FPS or an Instruments trace.",
                                   "measurements": measurements]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
