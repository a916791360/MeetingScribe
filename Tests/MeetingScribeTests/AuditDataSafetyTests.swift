import AVFoundation
import XCTest
@testable import MeetingScribe

final class AuditDataSafetyTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testDraftCreationReportsDiskFailure() throws {
        let parent = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let blockedRoot = parent.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedRoot)
        XCTAssertThrowsError(try SessionStorage(rootURL: blockedRoot).createDraftSession(captureMode: .mixed))
    }

    func testImportedInputWAVPreservesOriginalAndManifest() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root.appendingPathComponent("meetings"))
        let session = try storage.createDraftSession(captureMode: .imported)
        let input = root.appendingPathComponent("input.wav")
        let original = Data("synthetic original audio".utf8)
        try original.write(to: input)
        let copied = try storage.copyImportedAudio(url: input, into: session)
        let normalized = storage.inputURL(for: session, preferredFileName: "input.wav")
        XCTAssertNotEqual(copied, normalized)
        try Data("normalized audio".utf8).write(to: normalized)
        XCTAssertEqual(try Data(contentsOf: copied), original)
        XCTAssertEqual(try storage.session(with: session.id).sourceFileName, copied.lastPathComponent)
        let manifest = root.appendingPathComponent("session.json")
        try original.write(to: manifest)
        XCTAssertThrowsError(try storage.copyImportedAudio(url: manifest, into: session))
        XCTAssertNoThrow(try storage.session(with: session.id))
    }

    func testCorruptedSessionIsReportedAndFilePreserved() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        let session = try storage.createDraftSession(captureMode: .imported)
        let metadata = storage.folderURL(for: session).appendingPathComponent("session.json")
        XCTAssertEqual(storage.loadSessions().count, 1)
        try Data("{truncated".utf8).write(to: metadata)
        XCTAssertEqual(storage.loadSessionsReport().sessions.count, 0)
        XCTAssertEqual(storage.loadSessionsReport().issues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    }

    func testImportWithOldDraftSnapshotPreservesConcurrentRename() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root.appendingPathComponent("data"))
        let draft = try storage.createDraftSession(captureMode: .imported)
        try storage.update(draft.id) {
            $0.title = "导入期间的人工名称"
            $0.titleManuallyEdited = true
        }
        let source = root.appendingPathComponent("fixture.wav")
        try Data("synthetic audio bytes".utf8).write(to: source)
        _ = try storage.copyImportedAudio(url: source, into: draft)
        let saved = try storage.session(with: draft.id)
        XCTAssertEqual(saved.title, "导入期间的人工名称")
        XCTAssertTrue(saved.titleManuallyEdited == true)
        XCTAssertEqual(saved.sourceFileName, source.lastPathComponent)
    }

    @MainActor
    func testSingleTrackDigitalSilenceSkipsCLIAndQuietSignalStillReachesCLI() async throws {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } } }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = try storage.createDraftSession(captureMode: .imported)
        session.status = .failed
        session.sourceFileName = "source.wav"
        try storage.save(session)
        let audioURL = storage.folderURL(for: session).appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        func writeAudio(amplitude: Float) throws {
            for frame in 0..<16_000 { buffer.floatChannelData![0][frame] = amplitude * sinf(2 * .pi * 440 * Float(frame) / 16_000) }
            let file = try AVAudioFile(forWriting: audioURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
            try file.write(from: buffer)
        }
        try writeAudio(amplitude: 0)
        let model = root.appendingPathComponent("model.bin")
        try Data().write(to: model)
        let store = MeetingStore(storage: storage)
        store.summarySettings = .default
        store.whisperCLIPath = "/usr/bin/false"
        store.whisperModelPath = model.path
        store.retryProcessing(session)
        for _ in 0..<600 where store.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isProcessing)
        let silent = try storage.session(with: session.id)
        XCTAssertEqual(silent.status, .ready, silent.errorMessage ?? "")
        XCTAssertTrue(silent.transcriptSegments.isEmpty)
        // Below the previous -40dB cutoff, but still a valid signal: must reach CLI.
        try writeAudio(amplitude: 0.005)
        store.retryProcessing(silent)
        for _ in 0..<600 where store.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isProcessing)
        XCTAssertEqual(try storage.session(with: session.id).status, .failed)
    }

    @MainActor
    func testRetryNormalizesM4ABeforeWhisper() async throws {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set("localRules", forKey: "meetingScribe.summaryProvider")
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = try storage.createDraftSession(captureMode: .imported)
        let folder = storage.folderURL(for: session)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for index in 0..<16_000 { buffer.floatChannelData![0][index] = 0.2 * sinf(2 * .pi * 440 * Float(index) / 16_000) }
        let wav = folder.appendingPathComponent("fixture.wav")
        do {
            let file = try AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
            try file.write(from: buffer)
        }
        let m4a = folder.appendingPathComponent("source.m4a")
        let converter = Process()
        converter.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        converter.arguments = ["-f", "m4af", "-d", "aac", wav.path, m4a.path]
        try converter.run()
        converter.waitUntilExit()
        XCTAssertEqual(converter.terminationStatus, 0)
        session.status = .failed
        session.sourceFileName = "source.m4a"
        try storage.save(session)
        let store = MeetingStore(storage: storage)
        let cli = root.appendingPathComponent("fake-whisper")
        try """
        #!/usr/bin/env python3
        import sys, json, struct
        from pathlib import Path
        args = sys.argv[1:]
        audio = args[args.index('-f') + 1]
        data = Path(audio).read_bytes()
        assert data[:4] == b'RIFF' and data[8:12] == b'WAVE'
        assert struct.unpack_from('<I', data, data.index(b'fmt ') + 12)[0] == 16000
        prefix = args[args.index('-of') + 1]
        Path(prefix + '.json').write_text(json.dumps({'transcription': []}))
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let model = root.appendingPathComponent("model.bin")
        try Data().write(to: model)
        store.whisperCLIPath = cli.path
        store.whisperModelPath = model.path
        store.retryProcessing(session)
        for _ in 0..<1_000 where store.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        if store.isProcessing { store.cancelProcessing() }
        XCTAssertFalse(store.isProcessing)
        let result = try storage.session(with: session.id)
        XCTAssertEqual(result.inputAudioFileName, "input.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("input.wav").path))
        XCTAssertEqual(result.status, .ready, result.errorMessage ?? "no error")

    }

    @MainActor
    func testFailedRetryPreservesSavedManualEditsAndMinutes() async throws {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set("localRules", forKey: "meetingScribe.summaryProvider")
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = try storage.createDraftSession(captureMode: .imported)
        session.status = .failed
        session.sourceFileName = "source.wav"
        session.transcriptSegments = [TranscriptSegment(start: 0, end: 1, text: "人工确认过的真实内容", confidence: 1)]
        session.transcriptSegments[0].manuallyEditedAt = Date()
        session.transcriptText = "人工确认过的真实内容"
        session.transcriptEditedAt = Date()
        session.analysis.minutesText = "之前保存的纪要正文"
        try storage.save(session)
        session = try storage.session(with: session.id)
        let audioURL = storage.folderURL(for: session).appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for index in 0..<16_000 { buffer.floatChannelData![0][index] = 0.2 * sinf(2 * .pi * 440 * Float(index) / 16_000) }
        let audio = try AVAudioFile(forWriting: audioURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        try audio.write(from: buffer)
        let model = root.appendingPathComponent("fake-model.bin")
        try Data("fake model".utf8).write(to: model)
        let store = MeetingStore(storage: storage)
        store.whisperCLIPath = "/usr/bin/false"
        store.whisperModelPath = model.path
        store.retryProcessing(session)
        let immediately = try storage.session(with: session.id)
        XCTAssertEqual(immediately.transcriptText, session.transcriptText)
        XCTAssertEqual(immediately.transcriptSegments, session.transcriptSegments)
        XCTAssertEqual(immediately.analysis.minutesText, session.analysis.minutesText)
        XCTAssertNotNil(immediately.transcriptEditedAt)
        for _ in 0..<200 where store.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        if store.isProcessing { store.cancelProcessing() }
        XCTAssertFalse(store.isProcessing)
        let failed = try storage.session(with: session.id)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.transcriptSegments, session.transcriptSegments)
    }
}
