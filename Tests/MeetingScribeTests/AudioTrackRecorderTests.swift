import AVFoundation
import CoreMedia
import XCTest
@testable import MeetingScribe

/// `AudioTrackRecorder` 的搬运正确性。
///
/// 真实的两路音频本机造不出来，但"**给一份 PCM，它能不能原样落成文件**"是能造的：
/// 手工拼一个 `CMSampleBuffer`（正是 ScreenCaptureKit 回调会给的东西）喂进去，
/// 再把文件读回来比对。这一段如果错了，逐字稿会变成噪音或干脆为空。
final class AudioTrackRecorderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribe-track-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - 正常路径

    func testWrittenFileHoldsTheSameSamplesThatWereFed() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let url = temporaryDirectory.appendingPathComponent("local.caf")
        let recorder = AudioTrackRecorder(url: url)

        let first = try XCTUnwrap(makeSampleBuffer(format: format, frames: 1_600, amplitude: 0.5))
        let second = try XCTUnwrap(makeSampleBuffer(format: format, frames: 1_600, amplitude: 0.25))
        recorder.append(first)
        recorder.append(second)
        recorder.finish()

        XCTAssertNil(recorder.failureReason)
        XCTAssertTrue(recorder.didWriteAudio)

        let written = try AVAudioFile(forReading: url)
        XCTAssertEqual(written.length, 3_200, "两批样本的帧数必须一帧不少地落进文件")
        XCTAssertEqual(written.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(written.fileFormat.channelCount, 1)
    }

    func testSamplesRoundTripAtTheRightAmplitude() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let url = temporaryDirectory.appendingPathComponent("remote.caf")
        let recorder = AudioTrackRecorder(url: url)
        recorder.append(try XCTUnwrap(makeSampleBuffer(format: format, frames: 512, amplitude: 0.75)))
        recorder.finish()

        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)

        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let peak = (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
        XCTAssertEqual(peak, 0.75, accuracy: 0.001, "写进去的幅度必须原样回来")
    }

    func testInterleavedFloat32SamplesAreAccepted() throws {
        // ScreenCaptureKit 的 `.microphone` 路在真机上给过 48 kHz / Float32 / 交错。
        // `AVAudioFormat.isStandard` 会把这种格式判成 false，之前就是因此把麦克风整路丢掉。
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)
        )
        XCTAssertFalse(format.isStandard, "这个断言钉住事故格式：它不是 AVAudioFormat 所谓 standard，但仍是合法 PCM")

        let url = temporaryDirectory.appendingPathComponent("interleaved-float.caf")
        let recorder = AudioTrackRecorder(url: url)
        recorder.append(try XCTUnwrap(makeSampleBuffer(format: format, frames: 2_400, amplitude: 0.4)))
        recorder.finish()

        XCTAssertNil(recorder.failureReason)
        XCTAssertTrue(recorder.didWriteAudio)

        let written = try AVAudioFile(forReading: url)
        XCTAssertEqual(written.length, 2_400)
        XCTAssertEqual(written.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(written.fileFormat.channelCount, 1)
    }

    // MARK: - 会静默毁数据的两种情形

    func testFormatChangeMidStreamStopsInsteadOfMixingFormats() throws {
        // 把两种格式混进同一个文件，得到的是一段"能播放但是噪音"的音频 ——
        // 属于本项目最怕的看不见的损坏。必须停手并把原因记下来。
        let first = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let second = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let url = temporaryDirectory.appendingPathComponent("mixed-format.caf")
        let recorder = AudioTrackRecorder(url: url)

        recorder.append(try XCTUnwrap(makeSampleBuffer(format: first, frames: 800, amplitude: 0.3)))
        recorder.append(try XCTUnwrap(makeSampleBuffer(format: second, frames: 800, amplitude: 0.3)))
        recorder.finish()

        XCTAssertNotNil(recorder.failureReason, "换了格式必须被记下来，不能悄悄继续写")

        let written = try AVAudioFile(forReading: url)
        XCTAssertEqual(written.length, 800, "只有换格式之前的那一批能落盘")
    }

    func testFinishWithoutAnyAudioRemovesTheEmptyFile() throws {
        let url = temporaryDirectory.appendingPathComponent("silent.caf")
        let recorder = AudioTrackRecorder(url: url)

        recorder.finish()

        XCTAssertFalse(recorder.didWriteAudio)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "没写出内容的空文件要删掉，否则后面的存在性判断会被它骗到"
        )
    }

    func testAppendingAfterFinishIsIgnored() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let url = temporaryDirectory.appendingPathComponent("late.caf")
        let recorder = AudioTrackRecorder(url: url)
        recorder.append(try XCTUnwrap(makeSampleBuffer(format: format, frames: 400, amplitude: 0.2)))
        recorder.finish()

        recorder.append(try XCTUnwrap(makeSampleBuffer(format: format, frames: 400, amplitude: 0.2)))

        let written = try AVAudioFile(forReading: url)
        XCTAssertEqual(written.length, 400)
    }

    // MARK: - 夹具：手工拼一个 ScreenCaptureKit 会给的音频样本

    private func makeSampleBuffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        amplitude: Float
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
