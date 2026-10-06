import AVFoundation
import CoreMedia
import Darwin
import XCTest
@testable import MeetingScribe

final class AuditRecordingPipelineTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ms-review-batch2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func wave(at url: URL, seconds: Int = 1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        for second in 0..<seconds {
            for frame in 0..<16_000 { buffer.floatChannelData![0][frame] = second == 0 ? 0.2 * sinf(2 * .pi * 440 * Float(frame) / 16_000) : 0 }
            try file.write(from: buffer)
        }
    }

    private func executable(at root: URL, body: String) throws -> URL {
        let path = root.appendingPathComponent("fake-whisper")
        try ("#!/usr/bin/env python3\n" + body).write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    @MainActor
    private func prepareStore(_ storage: SessionStorage) -> (MeetingStore, [(String, Any?)]) {
        let keys = ["appearance", "captureMode", "whisperCLIPath", "whisperModelPath", "glossaryText", "summaryProvider", "summaryModel", "summaryEndpoint"].map { "meetingScribe.\($0)" }
        let snapshot = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        UserDefaults.standard.set("localRules", forKey: "meetingScribe.summaryProvider")
        let store = MeetingStore(storage: storage)
        store.summarySettings = .default
        return (store, snapshot)
    }

    @MainActor
    private func restore(_ snapshot: [(String, Any?)]) {
        for (key, value) in snapshot {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, iterations: Int = 600) async throws {
        for _ in 0..<iterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "ReviewProbeTimeout", code: 1)
    }

    func testSampleTimestampGapIsPreserved() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let url = temp.appendingPathComponent("gapped.caf")
        let recorder = AudioTrackRecorder(url: url)
        recorder.append(try XCTUnwrap(makeSampleBuffer(format: format, frames: 1_600, amplitude: 0.3, presentationTime: 10)))
        recorder.append(try XCTUnwrap(makeSampleBuffer(format: format, frames: 1_600, amplitude: 0.3, presentationTime: 12)))
        recorder.finish()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 2.1, accuracy: 0.0001)
        XCTAssertNil(recorder.failureReason)
    }

    func testFailedTrackIsRejectedForDualTranscription() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let recorder = AudioTrackRecorder(url: temp.appendingPathComponent("partial.caf"))
        let first = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let changed = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        recorder.append(try XCTUnwrap(makeSampleBuffer(format: first, frames: 1_600, amplitude: 0.3)))
        recorder.append(try XCTUnwrap(makeSampleBuffer(format: changed, frames: 4_800, amplitude: 0.3, presentationTime: 0.1)))
        recorder.finish()
        XCTAssertNotNil(recorder.failureReason)
        XCTAssertTrue(recorder.didWriteAudio)
        XCTAssertFalse(recorder.isUsable)
    }

    func testCleaningPreservesDifferentSpeakers() {
        var local = TranscriptSegment(start: 0, end: 2, text: "这笔预算我们还没确认", confidence: 0.9)
        local.speaker = .local
        var remote = TranscriptSegment(start: 3, end: 5, text: "我明天提供最终报价。", confidence: 0.9)
        remote.speaker = .remote
        let cleaned = TranscriptCleaner.clean([local, remote])
        XCTAssertEqual(cleaned.count, 2)
        XCTAssertEqual(cleaned[0].speaker, .local)
        XCTAssertEqual(cleaned[1].text, remote.text)
        XCTAssertEqual(cleaned[1].speaker, .remote)
        local.text = "这个方案可以上线。"
        remote.text = local.text
        remote.start = 20
        remote.end = 22
        let repeated = TranscriptCleaner.clean([local, remote])
        XCTAssertEqual(repeated.count, 2)
    }

    func testCrosstalkPreservesOppositeDecisions() {
        let yes = TranscriptSegment(start: 0, end: 3, text: "这个方案可以上线。", confidence: 0.95)
        let no = TranscriptSegment(start: 0.1, end: 3.1, text: "这个方案不可以上线。", confidence: 0.9)
        let result = TranscriptMerger.merge(local: [yes], remote: [no])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, yes.text)
    }

    @MainActor
    func testChunkOwnershipPreservesTheCompleteBoundarySentence() {
        let firstWindow = MeetingStore.chunkWindow(index: 0, duration: 1_200)
        let secondWindow = MeetingStore.chunkWindow(index: 1, duration: 1_200)
        let truncated = TranscriptSegment(start: 599, end: 602, text: "下周一", confidence: 0.9)
        let complete = TranscriptSegment(start: 599, end: 606, text: "下周一交付最终报价单。", confidence: 0.9)
        let retained = MeetingStore.ownedSegments([truncated], index: 0, in: firstWindow)
            + MeetingStore.ownedSegments([complete], index: 1, in: secondWindow)
        XCTAssertEqual(retained.map(\.text), ["下周一", "下周一交付最终报价单。"])
    }

    @MainActor
    func testSecondTrackFailurePreservesFirstTrackCheckpoint() async throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let storage = SessionStorage(rootURL: temp.appendingPathComponent("data"))
        var session = try storage.createDraftSession(captureMode: .mixed)
        let folder = storage.folderURL(for: session)
        try wave(at: folder.appendingPathComponent("input.wav"))
        try wave(at: folder.appendingPathComponent("local.wav"), seconds: 601)
        try wave(at: folder.appendingPathComponent("remote.wav"), seconds: 601)
        session.status = .failed
        session.inputAudioFileName = "input.wav"
        session.localAudioFileName = "local.wav"
        session.remoteAudioFileName = "remote.wav"
        try storage.save(session)
        let cli = try executable(at: temp, body: """
        import sys, json
        from pathlib import Path
        args = sys.argv[1:]
        prefix = args[args.index('-of') + 1]
        if 'remote-0002' in prefix:
            sys.exit(42)
        second = prefix.endswith('0002')
        start = 600000 if second else 0
        text = '我方已经完成的内容。' if 'chunk-local-' in prefix else '对方第一段内容。'
        data = {'transcription': [{'timestamps': {'from':'00:00:00.000', 'to':'00:00:01.000'}, 'offsets':{'from':start,'to':start+1000}, 'text': text, 'tokens':[]}]}
        Path(prefix + '.json').write_text(json.dumps(data))
        """)
        let model = temp.appendingPathComponent("model.bin")
        try Data("fixture".utf8).write(to: model)
        let (store, snapshot) = prepareStore(storage)
        defer { restore(snapshot) }
        store.whisperCLIPath = cli.path
        store.whisperModelPath = model.path
        store.retryProcessing(session)
        try await waitFor { !store.isProcessing }
        let saved = try storage.session(with: session.id)
        XCTAssertEqual(saved.status, .failed)
        XCTAssertTrue(saved.transcriptText.contains("对方第一段内容"))
        XCTAssertTrue(saved.transcriptText.contains("我方已经完成的内容"))
        XCTAssertTrue(saved.transcriptSegments.contains { $0.speaker == .local })
        XCTAssertTrue(saved.transcriptSegments.contains { $0.speaker == .remote })
    }

    @MainActor
    func testDualTrackCrashRecoveryDoesNotRepeatFinishedChunks() async throws {
        try await exerciseDualTrackRecovery(retainPrevious: false, changeSource: false)
    }

    @MainActor
    func testDualTrackRetryRecoveryPreservesOldEditsUntilSuccess() async throws {
        try await exerciseDualTrackRecovery(retainPrevious: true, changeSource: false)
    }

    @MainActor
    func testDualTrackRecoveryInvalidatesOnlyChangedSource() async throws {
        try await exerciseDualTrackRecovery(retainPrevious: false, changeSource: true)
    }

    @MainActor
    private func exerciseDualTrackRecovery(retainPrevious: Bool, changeSource: Bool) async throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let storage = SessionStorage(rootURL: temp.appendingPathComponent("data"))
        var session = try storage.createDraftSession(captureMode: .mixed)
        let folder = storage.folderURL(for: session)
        try wave(at: folder.appendingPathComponent("input.wav"))
        try wave(at: folder.appendingPathComponent("local.wav"), seconds: 601)
        try wave(at: folder.appendingPathComponent("remote.wav"), seconds: 601)
        session.status = .failed
        session.inputAudioFileName = "input.wav"
        session.localAudioFileName = "local.wav"
        session.remoteAudioFileName = "remote.wav"
        if retainPrevious {
            session.transcriptText = "人工校正必须保留直到新版转写完成。"
            session.analysis.minutesText = "已有纪要不可因恢复失败而丢失。"
        }
        try storage.save(session)
        let calls = temp.appendingPathComponent("calls.txt")
        let failedOnce = temp.appendingPathComponent("failed-once")
        let cli = try executable(at: temp, body: """
        import sys, json
        from pathlib import Path
        args = sys.argv[1:]
        prefix = args[args.index('-of') + 1]
        name = Path(prefix).name
        with Path('\(calls.path)').open('a') as f: f.write(name + '\\n')
        if 'remote-0002' in name and not Path('\(failedOnce.path)').exists():
            sys.exit(42)
        start = 600000 if name.endswith('0002') else 0
        text = '我方合成内容。' if 'local-' in name else '对方合成内容。'
        data = {'transcription':[{'timestamps':{'from':'00:00:00.000','to':'00:00:01.000'},'offsets':{'from':start,'to':start+1000},'text':text,'tokens':[]}]}
        Path(prefix + '.json').write_text(json.dumps(data))
        """)
        let model = temp.appendingPathComponent("model.bin")
        try Data("fixture".utf8).write(to: model)
        let (first, snapshot) = prepareStore(storage)
        defer { restore(snapshot) }
        first.whisperCLIPath = cli.path
        first.whisperModelPath = model.path
        if retainPrevious { await first.renameSession(session, to: "用户指定的会议名称") }
        first.retryProcessing(session)
        try await waitFor { !first.isProcessing }
        var interrupted = try storage.session(with: session.id)
        XCTAssertEqual(interrupted.status, .failed)
        XCTAssertEqual(interrupted.dualTrackCheckpoint?.local?.completedChunks, 2)
        XCTAssertEqual(interrupted.dualTrackCheckpoint?.remote?.completedChunks, 1)
        if retainPrevious {
            XCTAssertEqual(interrupted.transcriptText, session.transcriptText)
            XCTAssertEqual(interrupted.analysis.minutesText, session.analysis.minutesText)
        }
        // Simulate persisted processing state left by a process exit, using only fixtures.
        interrupted.status = .processing
        try storage.save(interrupted)
        try Data().write(to: failedOnce)
        if changeSource {
            let handle = try FileHandle(forUpdating: folder.appendingPathComponent("local.wav"))
            let length = try handle.seekToEnd()
            try handle.seek(toOffset: length - 1)
            try handle.write(contentsOf: Data([1]))
            try handle.close()
        }
        UserDefaults.standard.set(cli.path, forKey: "meetingScribe.whisperCLIPath")
        UserDefaults.standard.set(model.path, forKey: "meetingScribe.whisperModelPath")
        let recovered = MeetingStore(storage: storage)
        try await waitFor { recovered.sessions.first?.status == .ready }
        let names = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(names.filter { $0 == "chunk-local-0001" }.count, changeSource ? 2 : 1)
        XCTAssertEqual(names.filter { $0 == "chunk-local-0002" }.count, changeSource ? 2 : 1)
        XCTAssertEqual(names.filter { $0 == "chunk-remote-0001" }.count, 1)
        XCTAssertEqual(names.filter { $0 == "chunk-remote-0002" }.count, 3)
        let saved = try storage.session(with: session.id)
        if retainPrevious { XCTAssertEqual(saved.title, "用户指定的会议名称") }
        XCTAssertTrue(saved.transcriptSegments.contains { $0.speaker == .local })
        XCTAssertTrue(saved.transcriptSegments.contains { $0.speaker == .remote })
    }

    @MainActor
    func testSingleTrackRecoveryRetainsEditsAndSkipsCompletedChunk() async throws {
        try await exerciseSingleTrackRecovery(changeModel: false)
    }

    @MainActor
    func testSingleTrackRecoveryInvalidatesChangedModel() async throws {
        try await exerciseSingleTrackRecovery(changeModel: true)
    }

    @MainActor
    private func exerciseSingleTrackRecovery(changeModel: Bool) async throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let storage = SessionStorage(rootURL: temp.appendingPathComponent("data"))
        var session = try storage.createDraftSession(captureMode: .imported)
        try wave(at: storage.folderURL(for: session).appendingPathComponent("input.wav"), seconds: 601)
        session.status = .failed
        session.sourceFileName = "input.wav"
        session.inputAudioFileName = "input.wav"
        session.transcriptText = "人工校正应在失败后继续保留。"
        session.analysis.minutesText = "已有纪要。"
        try storage.save(session)
        let calls = temp.appendingPathComponent("calls.txt")
        let release = temp.appendingPathComponent("release")
        let cli = try executable(at: temp, body: """
        import sys, json
        from pathlib import Path
        args = sys.argv[1:]
        prefix = args[args.index('-of') + 1]
        name = Path(prefix).name
        with Path('\(calls.path)').open('a') as f: f.write(name + '\\n')
        if name.endswith('0002') and not Path('\(release.path)').exists(): sys.exit(42)
        start = 600000 if name.endswith('0002') else 0
        data = {'transcription':[{'timestamps':{'from':'00:00:00.000','to':'00:00:01.000'},'offsets':{'from':start,'to':start+1000},'text':'合成恢复结果。','tokens':[]}]}
        Path(prefix + '.json').write_text(json.dumps(data))
        """)
        let model = temp.appendingPathComponent("model.bin")
        try Data("fixture".utf8).write(to: model)
        let (first, snapshot) = prepareStore(storage)
        defer { restore(snapshot) }
        first.whisperCLIPath = cli.path
        first.whisperModelPath = model.path
        first.retryProcessing(session)
        try await waitFor { !first.isProcessing }
        var interrupted = try storage.session(with: session.id)
        XCTAssertEqual(interrupted.status, .failed)
        XCTAssertEqual(interrupted.transcriptText, session.transcriptText)
        XCTAssertEqual(interrupted.analysis.minutesText, session.analysis.minutesText)
        XCTAssertEqual(interrupted.singleTrackCheckpoint?.track.completedChunks, 1)
        XCTAssertEqual(interrupted.singleTrackCheckpoint?.track.segments.count, 1)
        interrupted.status = .processing
        try storage.save(interrupted)
        try Data().write(to: release)
        if changeModel { try Data("updated".utf8).write(to: model) }
        UserDefaults.standard.set(cli.path, forKey: "meetingScribe.whisperCLIPath")
        UserDefaults.standard.set(model.path, forKey: "meetingScribe.whisperModelPath")
        let recovered = MeetingStore(storage: storage)
        try await waitFor { recovered.sessions.first?.status == .ready }
        let names = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(names.filter { $0 == "chunk-0001" }.count, changeModel ? 2 : 1)
        XCTAssertEqual(names.filter { $0 == "chunk-0002" }.count, 3)
        let saved = try storage.session(with: session.id)
        XCTAssertNil(saved.singleTrackCheckpoint)
        XCTAssertNil(saved.processingRetainsPreviousResults)
        XCTAssertTrue(saved.transcriptText.contains("合成恢复结果"))
    }

    @MainActor
    func testUnequalTrackDurationsCountActualCompletedChunks() async throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let storage = SessionStorage(rootURL: temp.appendingPathComponent("data"))
        var session = try storage.createDraftSession(captureMode: .mixed)
        let folder = storage.folderURL(for: session)
        try wave(at: folder.appendingPathComponent("input.wav"))
        try wave(at: folder.appendingPathComponent("local.wav"), seconds: 601)
        try wave(at: folder.appendingPathComponent("remote.wav"))
        session.status = .failed
        session.inputAudioFileName = "input.wav"
        session.localAudioFileName = "local.wav"
        session.remoteAudioFileName = "remote.wav"
        try storage.save(session)
        let cli = try executable(at: temp, body: """
        import sys, json
        from pathlib import Path
        args = sys.argv[1:]
        prefix = args[args.index('-of') + 1]
        if 'remote-' in prefix: sys.exit(42)
        start = 600000 if prefix.endswith('0002') else 0
        data = {'transcription':[{'timestamps':{'from':'00:00:00.000','to':'00:00:01.000'},'offsets':{'from':start,'to':start+1000},'text':'我方合成内容。','tokens':[]}]}
        Path(prefix + '.json').write_text(json.dumps(data))
        """)
        let model = temp.appendingPathComponent("model.bin")
        try Data("fixture".utf8).write(to: model)
        let (store, snapshot) = prepareStore(storage)
        defer { restore(snapshot) }
        store.whisperCLIPath = cli.path
        store.whisperModelPath = model.path
        store.retryProcessing(session)
        try await waitFor { !store.isProcessing }
        let saved = try storage.session(with: session.id)
        XCTAssertEqual(saved.processingCompletedChunks, 2)
        XCTAssertEqual(saved.processingTotalChunks, 3)
        XCTAssertEqual(try XCTUnwrap(saved.processingProgress), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(saved.dualTrackCheckpoint?.local?.completedChunks, 2)
        XCTAssertEqual(saved.dualTrackCheckpoint?.remote?.completedChunks, 0)
    }

    @MainActor
    func testDeletionWaitsForOldTaskBeforeStartingAnother() async throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let storage = SessionStorage(rootURL: temp.appendingPathComponent("data"))
        var old = try storage.createDraftSession(captureMode: .imported)
        var new = try storage.createDraftSession(captureMode: .imported)
        old.status = .failed; old.sourceFileName = "input.wav"
        new.status = .failed; new.sourceFileName = "input.wav"
        for session in [old, new] { try storage.save(session); try wave(at: storage.folderURL(for: session).appendingPathComponent("input.wav")) }
        let markers = temp.appendingPathComponent("markers")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let cli = try executable(at: temp, body: """
        import sys, os, time, signal, json
        from pathlib import Path
        args = sys.argv[1:]
        audio = args[args.index('-f') + 1]
        prefix = args[args.index('-of') + 1]
        name = 'old' if '\(old.folderName)' in audio else 'new'
        base = Path('\(markers.path)')
        release = base / ('release-' + name)
        def terminate(signum, frame):
            while not release.exists(): time.sleep(0.01)
            sys.exit(143)
        signal.signal(signal.SIGTERM, terminate)
        (base / (name + '.pid')).write_text(str(os.getpid()))
        while not release.exists(): time.sleep(0.01)
        data = {'transcription':[{'timestamps':{'from':'00:00:00.000','to':'00:00:01.000'},'offsets':{'from':0,'to':1000},'text':'合成测试句。','tokens':[]}]}
        Path(prefix + '.json').write_text(json.dumps(data))
        """)
        defer {
            for name in ["old", "new"] {
                if let str = try? String(contentsOf: markers.appendingPathComponent(name + ".pid"), encoding: .utf8), let pid = Int32(str) { _ = kill(pid, SIGKILL) }
            }
        }
        let model = temp.appendingPathComponent("model.bin")
        try Data("fixture".utf8).write(to: model)
        let (store, snapshot) = prepareStore(storage)
        defer { restore(snapshot) }
        store.whisperCLIPath = cli.path; store.whisperModelPath = model.path
        store.retryProcessing(old)
        try await waitFor { FileManager.default.fileExists(atPath: markers.appendingPathComponent("old.pid").path) }
        store.deleteSession(old)
        XCTAssertTrue(store.isProcessing)
        store.retryProcessing(new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markers.appendingPathComponent("new.pid").path))
        try await waitFor { !FileManager.default.fileExists(atPath: storage.folderURL(for: old).path) }
        store.retryProcessing(new)
        try await waitFor { FileManager.default.fileExists(atPath: markers.appendingPathComponent("new.pid").path) }
        XCTAssertEqual(try storage.session(with: new.id).status, .processing)
        XCTAssertTrue(store.isProcessing)
        try Data().write(to: markers.appendingPathComponent("release-new"))
        try await waitFor { (try? storage.session(with: new.id).status) == .ready }
    }

    func testCancellationFinishesEvenIfCLIRejectsSIGTERM() async throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let pidFile = temp.appendingPathComponent("hung.pid")
        let cli = try executable(at: temp, body: """
        import os, signal, time
        from pathlib import Path
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        Path('\(pidFile.path)').write_text(str(os.getpid()))
        while True: time.sleep(0.01)
        """)
        let model = temp.appendingPathComponent("model.bin")
        try Data().write(to: model)
        let audio = temp.appendingPathComponent("input.wav")
        try wave(at: audio)
        let runner = WhisperCLIRunner()
        let completed = ProbeCompletion()
        let task = Task {
            do { _ = try await runner.transcribe(audioURL: audio, cliURL: cli, modelURL: model, outputPrefix: temp.appendingPathComponent("out"), initialPrompt: "") }
            catch { }
            await completed.finish()
        }
        for _ in 0..<600 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        defer { _ = kill(pid, SIGKILL) }
        task.cancel()
        await runner.cancel()
        try await Task.sleep(for: .seconds(2))
        let stillWaiting = await completed.isFinished == false
        XCTAssertFalse(stillWaiting)
        XCTAssertNotEqual(kill(pid, 0), 0)
        _ = kill(pid, SIGKILL)
        await task.value
    }

    func testSharedEpochPreservesFirstPacketOffsetsAndActualLevels() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let origin = CMTime(seconds: 10, preferredTimescale: 16000)
        let local = AudioTrackRecorder(url: temp.appendingPathComponent("local.caf"), timelineOrigin: origin)
        let remote = AudioTrackRecorder(url: temp.appendingPathComponent("remote.caf"), timelineOrigin: origin)
        local.append(try XCTUnwrap(makeSampleBuffer(format: format, frames: 1600, amplitude: 0.3, presentationTime: 10.25)))
        remote.append(try XCTUnwrap(makeSampleBuffer(format: format, frames: 1600, amplitude: 0, presentationTime: 10.75)))
        XCTAssertGreaterThan(local.level, 0)
        XCTAssertEqual(remote.level, 0)
        local.finish(); remote.finish()
        let l = try AVAudioFile(forReading: local.outputURL)
        let r = try AVAudioFile(forReading: remote.outputURL)
        XCTAssertEqual(Double(l.length) / 16000, 0.35, accuracy: 0.0001)
        XCTAssertEqual(Double(r.length) / 16000, 0.85, accuracy: 0.0001)
    }

    func testRunawayCLILogIsTerminatedAndDiagnosticIsBounded() async throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let cli = try executable(at: temp, body: """
        import os, time
        os.write(2, b'x' * (34 * 1024 * 1024))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline: time.sleep(0.01)
        raise SystemExit(42)
        """)
        let model = temp.appendingPathComponent("model.bin")
        try Data().write(to: model)
        let audio = temp.appendingPathComponent("input.wav")
        try wave(at: audio)
        let runner = WhisperCLIRunner()
        let started = Date()
        do {
            _ = try await runner.transcribe(audioURL: audio, cliURL: cli, modelURL: model,
                outputPrefix: temp.appendingPathComponent("out"), initialPrompt: "")
            XCTFail("runaway log must terminate")
        } catch {
            XCTAssertLessThan(error.localizedDescription.count, 4_000)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testIndependentRepeatsBySameSpeakerArePreserved() {
        let first = TranscriptSegment(start: 0, end: 2, text: "这个方案可以上线。", confidence: 0.9, speaker: .local)
        let later = TranscriptSegment(start: 20, end: 22, text: first.text, confidence: 0.9, speaker: .local)
        XCTAssertEqual(TranscriptCleaner.clean([first, later]).count, 2)
    }

    private func makeSampleBuffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        amplitude: Float,
        presentationTime: Double = 0
    ) throws -> CMSampleBuffer? {
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        pcm.frameLength = frames
        let sampleCount = Int(frames) * Int(format.channelCount)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { samples.deallocate() }
        for sample in 0..<sampleCount {
            let frame = sample / Int(format.channelCount)
            let phase = 2 * Float.pi * 440 * Float(frame) / Float(format.sampleRate)
            samples[sample] = amplitude * sinf(phase)
        }

        if format.isInterleaved {
            guard let data = pcm.floatChannelData?[0] else { return nil }
            data.update(from: samples, count: sampleCount)
        } else {
            for channelIndex in 0..<Int(format.channelCount) {
                guard let channel = pcm.floatChannelData?[channelIndex] else { return nil }
                for frame in 0..<Int(frames) {
                    channel[frame] = samples[frame * Int(format.channelCount) + channelIndex]
                }
            }
        }

        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        let byteCount = sampleCount * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        guard CMBlockBufferReplaceDataBytes(
            with: samples,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        ) == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: CMTime(seconds: presentationTime, preferredTimescale: 16_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }
}

private actor ProbeCompletion {
    private(set) var isFinished = false
    func finish() { isFinished = true }
}
