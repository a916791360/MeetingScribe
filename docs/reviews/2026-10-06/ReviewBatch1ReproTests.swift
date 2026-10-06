import AVFoundation
import XCTest
@testable import MeetingScribe

final class ReviewBatch1ReproTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testDraftCreationReturnsSuccessWhenRootIsARegularFile() throws {
        let parent = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let blockedRoot = parent.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedRoot)
        let storage = SessionStorage(rootURL: blockedRoot)
        let draft = storage.createDraftSession(captureMode: .mixed)
        XCTAssertEqual(draft.status, .recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.folderURL(for: draft).appendingPathComponent("session.json").path))
        XCTAssertThrowsError(try storage.session(with: draft.id))
        print("REPRO: draft returned recording status but no session.json exists")
    }

    func testCorruptedSessionDisappearsWithoutLoadError() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        let session = storage.createDraftSession(captureMode: .imported)
        let metadata = storage.folderURL(for: session).appendingPathComponent("session.json")
        XCTAssertEqual(storage.loadSessions().count, 1)
        try Data("{truncated".utf8).write(to: metadata)
        XCTAssertEqual(storage.loadSessions().count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
        print("REPRO: corrupted session omitted; metadata still exists")
    }

    @MainActor
    func testRetryPassesOriginalM4AToTheInstalledWhisperEngine() async throws {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set("localRules", forKey: "meetingScribe.summaryProvider")
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = storage.createDraftSession(captureMode: .imported)
        let folder = storage.folderURL(for: session)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for index in 0..<16_000 { buffer.floatChannelData![0][index] = 0 }
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
        store.whisperCLIPath = "/Applications/MeetingScribe.app/Contents/Resources/whisper/bin/whisper-cli"
        store.whisperModelPath = "/Applications/MeetingScribe.app/Contents/Resources/whisper/models/ggml-small.bin"
        store.retryProcessing(session)
        for _ in 0..<1_000 where store.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        if store.isProcessing { store.cancelProcessing() }
        XCTAssertFalse(store.isProcessing)
        let result = try storage.session(with: session.id)
        XCTAssertEqual(result.inputAudioFileName, "source.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("input.wav").path))
        XCTAssertEqual(result.status, .failed)
        print("REPRO: retry sent source.m4a without conversion; engine result: \(result.errorMessage ?? "nil")")
        let normalized = folder.appendingPathComponent("input.wav")
        try await AudioTranscoder().convertToWav(inputURL: m4a, outputURL: normalized)
        _ = try await WhisperCLIRunner().transcribe(
            audioURL: normalized,
            cliURL: URL(fileURLWithPath: store.whisperCLIPath),
            modelURL: URL(fileURLWithPath: store.whisperModelPath),
            outputPrefix: folder.appendingPathComponent("control-converted"),
            duration: 1,
            initialPrompt: ""
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("control-converted.json").path))
        print("CONTROL: the same M4A converted to input.wav produces Whisper JSON successfully")
    }

    @MainActor
    func testRetryErasesSavedManualEditsBeforeAnyTranscriptionRuns() async throws {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set("localRules", forKey: "meetingScribe.summaryProvider")
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = storage.createDraftSession(captureMode: .imported)
        session.status = .failed
        session.sourceFileName = "source.wav"
        session.transcriptSegments = [TranscriptSegment(start: 0, end: 1, text: "人工确认过的真实内容", confidence: 1)]
        session.transcriptSegments[0].manuallyEditedAt = Date()
        session.transcriptText = "人工确认过的真实内容"
        session.transcriptEditedAt = Date()
        session.analysis.minutesText = "之前保存的纪要正文"
        try storage.save(session)
        let audioURL = storage.folderURL(for: session).appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        let audio = try AVAudioFile(forWriting: audioURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        try audio.write(from: buffer)
        let model = root.appendingPathComponent("fake-model.bin")
        try Data("fake model".utf8).write(to: model)
        let store = MeetingStore(storage: storage)
        store.whisperCLIPath = "/usr/bin/false"
        store.whisperModelPath = model.path
        store.retryProcessing(session)
        let immediately = try storage.session(with: session.id)
        XCTAssertEqual(immediately.transcriptText, "")
        XCTAssertEqual(immediately.transcriptSegments.count, 0)
        XCTAssertEqual(immediately.analysis.minutesText, "")
        XCTAssertNotNil(immediately.transcriptEditedAt)
        print("REPRO: saved manual transcript and minutes erased synchronously before task runs")
        for _ in 0..<200 where store.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        if store.isProcessing { store.cancelProcessing() }
        XCTAssertFalse(store.isProcessing)
        let failed = try storage.session(with: session.id)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.transcriptSegments.count, 0)
        print("REPRO: after CLI failure, old manual transcript is still absent")
    }
}
