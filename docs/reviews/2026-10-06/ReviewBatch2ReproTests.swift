import AVFoundation
import CoreMedia
import Darwin
import XCTest
@testable import MeetingScribe

final class ReviewBatch2ReproTests: XCTestCase {
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

    func testSampleTimestampGapIsRemovedFromRecordedFile() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let url = temp.appendingPathComponent("gapped.caf")
        let recorder = AudioTrackRecorder(url: url)
        recorder.append(try XCTUnwrap(makeSampleBuffer(format: format, frames: 1_600, amplitude: 0.3, presentationTime: 10)))
        recorder.append(try XCTUnwrap(makeSampleBuffer(format: format, frames: 1_600, amplitude: 0.3, presentationTime: 12)))
        recorder.finish()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 0.2, accuracy: 0.0001)
        XCTAssertNil(recorder.failureReason)
        print("REPRO BUG-006: PTS 10.0 and 12.0, each 0.1 seconds, recorded as 0.2 seconds instead of a 2.1-second timeline")
    }

    func testFailedTrackStillLooksUsableToResultSelection() throws {
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
        print("REPRO BUG-007: partial track has failureReason but didWriteAudio=true, the only flag makeResult tests")
    }

    func testCleaningMergesDifferentSpeakersIntoOneLocalSegment() {
        var local = TranscriptSegment(start: 0, end: 2, text: "这笔预算我们还没确认", confidence: 0.9)
        local.speaker = .local
        var remote = TranscriptSegment(start: 3, end: 5, text: "我明天提供最终报价。", confidence: 0.9)
        remote.speaker = .remote
        let cleaned = TranscriptCleaner.clean([local, remote])
        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned[0].speaker, .local)
        XCTAssertTrue(cleaned[0].text.contains(remote.text))
        print("REPRO BUG-008: local + remote merged into one local segment, remote ownership lost")
        local.text = "这个方案可以上线。"
        remote.text = local.text
        remote.start = 20
        remote.end = 22
        let repeated = TranscriptCleaner.clean([local, remote])
        XCTAssertEqual(repeated.count, 1)
        print("REPRO BUG-008: separate speakers repeating a confirmation 20 seconds apart collapsed into one")
    }

    func testCrosstalkDeduplicationDeletesTheOppositeDecision() {
        let yes = TranscriptSegment(start: 0, end: 3, text: "这个方案可以上线。", confidence: 0.95)
        let no = TranscriptSegment(start: 0.1, end: 3.1, text: "这个方案不可以上线。", confidence: 0.9)
        let result = TranscriptMerger.merge(local: [yes], remote: [no])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, yes.text)
        print("REPRO BUG-009: overlapping '可以上线' and '不可以上线' reduced to the affirmative sentence")
    }

    @MainActor
    func testChunkOwnershipDiscardsTheMoreCompleteBoundarySentence() {
        let firstWindow = MeetingStore.chunkWindow(index: 0, duration: 1_200)
        let secondWindow = MeetingStore.chunkWindow(index: 1, duration: 1_200)
        let truncated = TranscriptSegment(start: 599, end: 602, text: "下周一", confidence: 0.9)
        let complete = TranscriptSegment(start: 599, end: 606, text: "下周一交付最终报价单。", confidence: 0.9)
        let retained = MeetingStore.ownedSegments([truncated], index: 0, in: firstWindow)
            + MeetingStore.ownedSegments([complete], index: 1, in: secondWindow)
        XCTAssertEqual(retained.map(\.text), ["下周一"])
        print("REPRO BUG-015: earlier chunk ends at 602; complete overlapping sentence ending at 606 is discarded because its start is 599 < 600")
    }

    @MainActor
    func testSecondTrackCheckpointOverwritesTheCompletedFirstTrack() async throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let storage = SessionStorage(rootURL: temp.appendingPathComponent("data"))
        var session = storage.createDraftSession(captureMode: .mixed)
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
            print('injected remote chunk failure', file=sys.stderr)
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
        XCTAssertFalse(saved.transcriptText.contains("我方已经完成的内容"))
        XCTAssertTrue(saved.transcriptSegments.allSatisfy { $0.speaker == nil })
        print("REPRO BUG-010: remote chunk 2 failure left only remote chunk 1, completed local transcript absent and no speaker tags")
    }

    @MainActor
    func testDeletedOldTaskClearsNewTaskBusyState() async throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let storage = SessionStorage(rootURL: temp.appendingPathComponent("data"))
        var old = storage.createDraftSession(captureMode: .imported)
        var new = storage.createDraftSession(captureMode: .imported)
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
        store.retryProcessing(new)
        try await waitFor { FileManager.default.fileExists(atPath: markers.appendingPathComponent("new.pid").path) }
        try Data().write(to: markers.appendingPathComponent("release-old"))
        try await waitFor { !store.isProcessing }
        XCTAssertEqual(try storage.session(with: new.id).status, .processing)
        XCTAssertFalse(store.isProcessing)
        print("REPRO BUG-011: old deleted task completion set isProcessing=false while new task and new session were still processing")
        try Data().write(to: markers.appendingPathComponent("release-new"))
        try await waitFor { (try? storage.session(with: new.id).status) == .ready }
    }

    func testCancellationDoesNotFinishIfCLIRejectsSIGTERM() async throws {
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
        try await Task.sleep(for: .milliseconds(300))
        let stillWaiting = await completed.isFinished == false
        XCTAssertTrue(stillWaiting)
        XCTAssertEqual(kill(pid, 0), 0)
        print("REPRO BUG-012: task cancellation plus runner.cancel leaves a SIGTERM-ignoring CLI alive and the task waiting")
        _ = kill(pid, SIGKILL)
        await task.value
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
