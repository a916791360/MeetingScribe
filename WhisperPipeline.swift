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
    case audioDurationUnavailable
    case transcriptionTimedOut
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
        case .audioDurationUnavailable:
            return "无法读取音频时长。"
        case .transcriptionTimedOut:
            return "这一段转写超过预设时间没有完成，已停止本次处理。"
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
    private let processRunner = LocalProcessRunner()

    func convertToWav(inputURL: URL, outputURL: URL) async throws {
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

        let result = try await processRunner.run(
            executableURL: converter,
            arguments: [
                "-f", "WAVE",
                "-d", "LEI16@16000",
                "-c", "1",
                inputURL.path,
                outputURL.path
            ],
            environment: nil
        )

        guard result.status == 0 else {
            throw PipelineError.transcriptionFailed(
                result.failureMessage(default: "音频转 WAV 失败。")
            )
        }
    }

    func cancel() async {
        await processRunner.cancel()
    }
}

struct AudioDurationReader {
    func duration(for url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else {
            throw PipelineError.audioDurationUnavailable
        }
        return Double(file.length) / sampleRate
    }
}

actor WhisperCLIRunner {
    private let processRunner = LocalProcessRunner()

    func transcribe(
        audioURL: URL,
        cliURL: URL,
        modelURL: URL,
        outputPrefix: URL,
        offset: TimeInterval = 0,
        duration: TimeInterval? = nil,
        language: String = "zh"
    ) async throws -> WhisperTranscript {
        guard FileManager.default.fileExists(atPath: cliURL.path) else {
            throw PipelineError.missingBinary
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw PipelineError.missingModel
        }

        let jsonURL = outputPrefix.appendingPathExtension("json")
        let textURL = outputPrefix.appendingPathExtension("txt")
        try FileManager.default.createDirectory(
            at: outputPrefix.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: jsonURL.path) {
            try FileManager.default.removeItem(at: jsonURL)
        }
        if FileManager.default.fileExists(atPath: textURL.path) {
            try FileManager.default.removeItem(at: textURL)
        }

        var arguments = [
            "-m", modelURL.path,
            "-f", audioURL.path,
            "-l", language,
            "-t", "\(min(8, max(4, ProcessInfo.processInfo.activeProcessorCount - 2)))",
            // The bundled whisper.cpp Metal backend crashes on this machine.
            // Keep transcription on the stable Apple Silicon CPU path for now.
            "-ng",
            "-oj",
            "-ojf",
            "-np",
            "--prompt", "这是一场中文工作会议，内容涉及产品、技术、需求、项目和业务讨论。",
            "-of", outputPrefix.path
        ]

        if offset > 0 {
            arguments.append(contentsOf: ["-ot", "\(Int((offset * 1000).rounded()))"])
        }
        if let duration, duration > 0 {
            arguments.append(contentsOf: ["-d", "\(Int((duration * 1000).rounded()))"])
        }

        let result = try await processRunner.run(
            executableURL: cliURL,
            arguments: arguments,
            environment: [
                "DYLD_LIBRARY_PATH": cliURL.deletingLastPathComponent().path
            ]
        )

        if result.status != 0 {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw PipelineError.transcriptionFailed(
                result.failureMessage(default: "whisper-cli 运行失败。")
            )
        }

        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw PipelineError.missingJSONOutput
        }

        let data = try Data(contentsOf: jsonURL)
        let raw = try JSONDecoder().decode(WhisperRawTranscript.self, from: data)
        return WhisperTranscript(raw: raw)
    }

    func cancel() async {
        await processRunner.cancel()
    }
}

private struct LocalProcessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String

    func failureMessage(default fallback: String, limit: Int = 2_000) -> String {
        let combined = [standardError, standardOutput]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !combined.isEmpty else { return fallback }
        if combined.count <= limit { return combined }
        return String(combined.prefix(limit)) + "\n（错误日志已截断）"
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private actor LocalProcessRunner {
    private var activeProcess: Process?

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> LocalProcessResult {
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        let stdoutURL = runDirectory.appendingPathComponent("stdout.log")
        let stderrURL = runDirectory.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let process = Process()
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            process.terminationHandler = nil
            activeProcess = nil
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: runDirectory)
        }

        process.executableURL = executableURL
        process.arguments = arguments
        process.qualityOfService = .userInitiated
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        var mergedEnvironment = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment {
                if key == "DYLD_LIBRARY_PATH",
                   let existing = mergedEnvironment[key],
                   !existing.isEmpty {
                    mergedEnvironment[key] = "\(value):\(existing)"
                } else {
                    mergedEnvironment[key] = value
                }
            }
        }
        process.environment = mergedEnvironment

        activeProcess = process
        let processBox = ProcessBox(process)

        let terminationStatus: Int32 = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { terminatedProcess in
                    continuation.resume(returning: terminatedProcess.terminationStatus)
                }

                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            processBox.process.terminate()
        })

        process.terminationHandler = nil
        activeProcess = nil
        try Task.checkCancellation()

        let standardOutput = String(
            decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(),
            as: UTF8.self
        )
        let standardError = String(
            decoding: (try? Data(contentsOf: stderrURL)) ?? Data(),
            as: UTF8.self
        )

        return LocalProcessResult(
            status: terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }

    func cancel() {
        activeProcess?.terminate()
    }
}

struct WhisperTranscript {
    let raw: WhisperRawTranscript
    let segments: [TranscriptSegment]
    let text: String

    init(raw: WhisperRawTranscript) {
        self.raw = raw
        self.segments = raw.transcription.compactMap { segment in
            let start = Double(segment.offsets.from) / 1000
            let end = Double(segment.offsets.to) / 1000
            let text = segment.text.trimmedLines
            guard !text.isEmpty, end >= start else { return nil }

            let tokenScores = segment.tokens.compactMap(\.p)
            let confidence = tokenScores.isEmpty
                ? 0.5
                : min(1, max(0, tokenScores.reduce(0, +) / Double(tokenScores.count)))

            return TranscriptSegment(
                start: start,
                end: end,
                text: text,
                confidence: confidence
            )
        }
        .sorted { $0.start < $1.start }
        self.text = segments.map(\.text).joined(separator: "\n")
    }
}
