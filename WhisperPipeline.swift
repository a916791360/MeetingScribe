@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit
import CoreGraphics

enum PipelineError: LocalizedError {
    case missingDisplay
    case missingAudioTrack
    case failedToCreateRecorder
    case failedToStartCapture
    case failedToStopCapture
    case missingBinary
    case missingModel
    case missingJSONOutput
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDisplay:
            return "没有找到可捕获的屏幕。"
        case .missingAudioTrack:
            return "没有找到可用的音频轨道。"
        case .failedToCreateRecorder:
            return "录音器创建失败。"
        case .failedToStartCapture:
            return "屏幕录制启动失败。"
        case .failedToStopCapture:
            return "屏幕录制停止失败。"
        case .missingBinary:
            return "找不到 whisper-cli。"
        case .missingModel:
            return "找不到 whisper 模型文件。"
        case .missingJSONOutput:
            return "找不到 whisper 的 JSON 输出。"
        case .transcriptionFailed(let message):
            return message
        }
    }
}

struct WhisperRawTranscript: Codable {
    let transcription: [WhisperRawSegment]
}

struct WhisperRawSegment: Codable {
    let timestamps: WhisperRawTimeRange
    let offsets: WhisperRawOffsetRange
    let text: String
    let tokens: [WhisperRawToken]
}

struct WhisperRawTimeRange: Codable {
    let from: String
    let to: String
}

struct WhisperRawOffsetRange: Codable {
    let from: Int
    let to: Int
}

struct WhisperRawToken: Codable {
    let text: String
    let p: Double?
    let id: Int?
}

@MainActor
final class MicrophoneRecordingSession: NSObject, AVAudioRecorderDelegate {
    private let outputURL: URL
    private var recorder: AVAudioRecorder?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {
        let granted = await Self.requestMicrophoneAccess()
        guard granted else { throw PipelineError.transcriptionFailed("麦克风权限未授权。") }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.delegate = self
        guard recorder.record() else {
            throw PipelineError.failedToCreateRecorder
        }
        self.recorder = recorder
    }

    func stop() -> URL {
        recorder?.stop()
        recorder = nil
        return outputURL
    }

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

@MainActor
final class MixedRecordingSession: NSObject, @preconcurrency SCRecordingOutputDelegate, @preconcurrency SCStreamDelegate {
    private let movieURL: URL
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var didStartRecording = false
    private var didFinishRecording = false
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private var stopError: Error?

    init(movieURL: URL) {
        self.movieURL = movieURL
    }

    func start() async throws {
        let granted = await Self.requestScreenAccess()
        guard granted else { throw PipelineError.transcriptionFailed("屏幕录制权限未授权。") }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw PipelineError.missingDisplay
        }

        let excludedWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = movieURL
        recordingConfiguration.outputFileType = .mov

        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)

        self.stream = stream
        self.recordingOutput = recordingOutput

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { [weak self] error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    Task { @MainActor in
                        self?.didStartRecording = true
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }

    func stop() async throws -> URL {
        guard let stream else { throw PipelineError.failedToStopCapture }

        return try await withCheckedThrowingContinuation { continuation in
            self.stopContinuation = continuation
            self.stopRequested = true

            stream.stopCapture { [weak self] error in
                if let error {
                    Task { @MainActor in
                        self?.stopError = error
                        self?.finishStopIfPossible()
                    }
                } else {
                    Task { @MainActor in
                        self?.finishStopIfPossible()
                    }
                }
            }
        }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        didStartRecording = true
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        didFinishRecording = true
        finishStopIfPossible()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        stopError = error
        finishStopIfPossible()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stopError = error
        finishStopIfPossible()
    }

    private func finishStopIfPossible() {
        guard stopRequested else { return }

        if let error = stopError {
            stopContinuation?.resume(throwing: error)
            stopContinuation = nil
            cleanup()
            return
        }

        guard didFinishRecording else { return }
        stopContinuation?.resume(returning: movieURL)
        stopContinuation = nil
        cleanup()
    }

    private func cleanup() {
        stream = nil
        recordingOutput = nil
        stopRequested = false
        didStartRecording = false
        didFinishRecording = false
        stopError = nil
    }

    static func requestScreenAccess() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }
}

struct AudioTranscoder {
    func convertToWav(inputURL: URL, outputURL: URL) throws {
        if inputURL == outputURL {
            return
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let converter = URL(fileURLWithPath: "/usr/bin/afconvert")
        guard FileManager.default.isExecutableFile(atPath: converter.path) else {
            throw PipelineError.transcriptionFailed("找不到系统音频转换工具 afconvert。")
        }

        let process = Process()
        process.executableURL = converter
        process.arguments = [
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            inputURL.path,
            outputURL.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PipelineError.transcriptionFailed(message.isEmpty ? "音频转 WAV 失败。" : message)
        }
    }
}

struct WhisperCLIRunner {
    func transcribe(audioURL: URL, cliURL: URL, modelURL: URL, language: String = "zh") async throws -> WhisperTranscript {
        guard FileManager.default.fileExists(atPath: cliURL.path) else {
            throw PipelineError.missingBinary
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw PipelineError.missingModel
        }

        let outputPrefix = audioURL.deletingPathExtension()
            .appendingPathExtension("whisper")
            .deletingPathExtension()

        let jsonURL = outputPrefix.appendingPathExtension("json")
        let textURL = outputPrefix.appendingPathExtension("txt")

        if FileManager.default.fileExists(atPath: jsonURL.path) {
            try FileManager.default.removeItem(at: jsonURL)
        }
        if FileManager.default.fileExists(atPath: textURL.path) {
            try FileManager.default.removeItem(at: textURL)
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = [
            "-ng",
            "-m", modelURL.path,
            "-f", audioURL.path,
            "-l", language,
            "-t", "\(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))",
            "-oj",
            "-ojf",
            "-np",
            "-of", outputPrefix.path
        ]
        process.environment = [
            "DYLD_LIBRARY_PATH": cliURL.deletingLastPathComponent().path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "whisper-cli 运行失败。"
            throw PipelineError.transcriptionFailed(message)
        }

        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw PipelineError.missingJSONOutput
        }

        let data = try Data(contentsOf: jsonURL)
        let raw = try JSONDecoder().decode(WhisperRawTranscript.self, from: data)
        return WhisperTranscript(raw: raw)
    }
}

struct WhisperTranscript {
    let raw: WhisperRawTranscript
    let segments: [TranscriptSegment]
    let text: String

    init(raw: WhisperRawTranscript) {
        self.raw = raw
        self.segments = raw.transcription.map { segment in
            let start = Double(segment.offsets.from) / 1000
            let end = Double(segment.offsets.to) / 1000
            let tokenScores = segment.tokens.compactMap(\.p)
            let confidence = tokenScores.isEmpty ? 0.5 : tokenScores.reduce(0, +) / Double(tokenScores.count)
            return TranscriptSegment(
                start: start,
                end: end,
                text: segment.text.trimmedLines,
                confidence: confidence
            )
        }
        self.text = segments.map(\.text).joined(separator: "\n")
    }
}
