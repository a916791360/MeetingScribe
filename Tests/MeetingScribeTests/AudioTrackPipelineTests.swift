import AVFoundation
import CoreMedia
import XCTest
@testable import MeetingScribe

/// 双声道（P2-2a）在**不碰 ScreenCaptureKit** 的前提下能验证的最大范围：
///
/// `AudioTrackRecorder` 落文件 → `AudioTranscoder` 归一化成 whisper 能吃的 wav →
/// `AudioLevelProbe` 判断这一路要不要转。
///
/// 唯一剩下没法自动验证的是"ScreenCaptureKit 到底有没有把两路分开投递"，
/// 那一条只能人工自测（见执行计划 §6.5）。
final class AudioTrackPipelineTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribe-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testRecordedTrackConvertsIntoAWhisperReadyWav() async throws {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let source = temporaryDirectory.appendingPathComponent("local.caf")
        let recorder = AudioTrackRecorder(url: source)
        for _ in 0..<4 {
            recorder.append(try XCTUnwrap(makeSampleBuffer(format: format, frames: 1_600, amplitude: 0.4)))
        }
        recorder.finish()
        XCTAssertTrue(recorder.didWriteAudio)

        let target = temporaryDirectory.appendingPathComponent("local.wav")
        try await AudioTranscoder().convertToWav(inputURL: source, outputURL: target)

        let converted = try AVAudioFile(forReading: target)
        XCTAssertEqual(converted.fileFormat.sampleRate, 16_000, "whisper 只吃 16 kHz")
        XCTAssertEqual(converted.fileFormat.channelCount, 1, "whisper 只吃单声道")
        XCTAssertEqual(converted.length, 6_400, "4 × 1600 帧，一帧都不能少")

        // 归一化之后还得听得见 —— 变成静音的话，这一路会被当成"没人说话"直接跳过。
        let probe = AudioLevelProbe()
        XCTAssertTrue(try probe.hasAudibleSignal(at: target))
    }

    func testProbeTreatsAllSilenceAsSilent() throws {
        let url = try writeWav(amplitude: 0)

        XCTAssertFalse(
            try AudioLevelProbe().hasAudibleSignal(at: url),
            "全程静音的一路必须能被识别出来 —— 送进 whisper 会凭空编出一整段话"
        )
    }

    func testProbeTreatsQuietButRealSpeechAsAudible() throws {
        // 0.02 是"很轻但在说话"的量级（约 -34 dBFS），必须在静音线之上：
        // 把安静的真实发言当成静音跳过，等于整段丢掉。
        let url = try writeWav(amplitude: 0.02)

        XCTAssertTrue(try AudioLevelProbe().hasAudibleSignal(at: url))
    }

    // MARK: - 夹具

    private func writeWav(amplitude: Float) throws -> URL {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let url = temporaryDirectory.appendingPathComponent("probe-\(amplitude).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<16_000 {
            let phase = 2 * Float.pi * 300 * Float(frame) / 16_000
            channel[frame] = amplitude * sinf(phase)
        }
        try file.write(from: buffer)
        return url
    }

    private func makeSampleBuffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        amplitude: Float
    ) throws -> CMSampleBuffer? {
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        pcm.frameLength = frames
        guard let channel = pcm.floatChannelData?[0] else { return nil }
        for frame in 0..<Int(frames) {
            let phase = 2 * Float.pi * 440 * Float(frame) / Float(format.sampleRate)
            channel[frame] = amplitude * sinf(phase)
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

        let byteCount = Int(frames) * MemoryLayout<Float>.size
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
            with: channel,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        ) == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: .zero,
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
