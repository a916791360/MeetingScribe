import AVFoundation
import Foundation

/// Builds the fallback recording from captured audio only. ScreenCaptureKit must
/// never receive a recording output, which also persists display pixels to MOV.
actor AudioOnlyRecordingAssembler {
    private let transcoder = AudioTranscoder()

    func assemble(tracks: [URL], output: URL) async throws {
        guard !tracks.isEmpty else { throw PipelineError.failedToStopCapture }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".audio-mix-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var inputs: [AVAudioFile] = []
        for (index, track) in tracks.enumerated() {
            let normalized = temporary.appendingPathComponent("track-\(index).wav")
            try await transcoder.convertToWav(inputURL: track, outputURL: normalized)
            let input = try AVAudioFile(forReading: normalized)
            guard input.processingFormat.sampleRate == 16_000, input.processingFormat.channelCount == 1,
                  input.length > 0 else { throw PipelineError.failedToStopCapture }
            inputs.append(input)
        }
        let result = temporary.appendingPathComponent("source.wav")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
              let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw PipelineError.failedToStopCapture
        }
        let total = inputs.map(\.length).max() ?? 0
        // One bounded block per iteration; a multi-hour recording never becomes
        // one giant array. Half gain with two sources prevents clipping.
        do {
            let destination = try AVAudioFile(forWriting: result, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            var position: AVAudioFramePosition = 0
            while position < total {
                let count = AVAudioFrameCount(min(16_384, total - position))
                mixed.frameLength = count
                guard let samples = mixed.floatChannelData?[0] else { throw PipelineError.failedToStopCapture }
                samples.update(repeating: 0, count: Int(count))
                for input in inputs where input.framePosition < input.length {
                    try input.read(into: scratch, frameCount: count)
                    guard let source = scratch.floatChannelData?[0] else { throw PipelineError.failedToStopCapture }
                    for frame in 0..<Int(scratch.frameLength) {
                        samples[frame] += source[frame] / Float(inputs.count)
                    }
                }
                for frame in 0..<Int(count) { samples[frame] = min(1, max(-1, samples[frame])) }
                try destination.write(from: mixed)
                position += AVAudioFramePosition(count)
            }
        }
        // Atomic replacement only after normalization/mixing/close succeed.
        // Rename keeps an existing source intact on any earlier failure.
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: result)
        } else {
            try FileManager.default.moveItem(at: result, to: output)
        }
    }
}
