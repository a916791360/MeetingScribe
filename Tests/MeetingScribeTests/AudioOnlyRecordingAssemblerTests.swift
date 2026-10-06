import AVFoundation
import XCTest
@testable import MeetingScribe

final class AudioOnlyRecordingAssemblerTests: XCTestCase {
    private func write(_ samples: [Float], to url: URL, rate: Double = 16000) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, sample) in samples.enumerated() { buffer.floatChannelData![0][i] = sample }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-audio-only-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func testMixedSourceKeepsSharedEpochSilenceAndDifferentTrackLengthsWithoutVideo() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local.wav"), remote = root.appendingPathComponent("remote.wav"), output = root.appendingPathComponent("source.wav")
        try write([Float](repeating: 0, count: 400) + [Float](repeating: 0.6, count: 1200), to: local)
        try write([Float](repeating: 0, count: 1600) + [Float](repeating: 0.4, count: 1600), to: remote)
        try await AudioOnlyRecordingAssembler().assemble(tracks: [local, remote], output: output)
        let result = try samples(output)
        XCTAssertEqual(result.count, 3200)
        XCTAssertEqual(result[200], 0, accuracy: 0.0001)
        XCTAssertEqual(result[800], 0.3, accuracy: 0.0001)
        XCTAssertEqual(result[2400], 0.2, accuracy: 0.0001)
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(video.isEmpty)
        XCTAssertEqual(audio.count, 1)
    }

    func testSingleTrackNormalizesSampleRateWithoutReducingItsGain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("local.wav"), output = root.appendingPathComponent("source.wav")
        try write([Float](repeating: 0.4, count: 4800), to: input, rate: 48000)
        try await AudioOnlyRecordingAssembler().assemble(tracks: [input], output: output)
        let result = try samples(output)
        XCTAssertEqual(result.count, 1600)
        XCTAssertEqual(result[800], 0.4, accuracy: 0.001)
    }

    func testFailedAssemblyDoesNotReplaceExistingSourceOrLeaveTemporaryFiles() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("source.wav")
        try write([Float](repeating: 0.2, count: 1600), to: output)
        let before = try Data(contentsOf: output)
        do {
            try await AudioOnlyRecordingAssembler().assemble(tracks: [root.appendingPathComponent("missing.wav")], output: output)
            XCTFail("Missing source must fail")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: output), before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".audio-mix-") })
    }

    func testIndependentFinalizationCompletesInsideCancelledOwner() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.wav"), output = root.appendingPathComponent("source.wav")
        try write([Float](repeating: 0.2, count: 1600), to: input)
        let owner = Task {
            let finalization = Task { try await AudioOnlyRecordingAssembler().assemble(tracks: [input], output: output) }
            try await finalization.value
        }
        owner.cancel()
        try await owner.value
        XCTAssertEqual(try samples(output).count, 1600)
    }
}
