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

/// 一次「混合录音」的产物（P2-2a 双声道）。
///
/// 保留原来的单路 `.mov`（播放与兜底转写都靠它），另外给出分开的两路：
/// `local` 是麦克风（我方），`remote` 是系统声音（对方）。
///
/// **两路都可能缺**：系统版本不给 `.microphone` output、权限没给、ScreenCaptureKit
/// 干脆没投递 —— 任何一种情况都必须能退回单路。缺一路不算错，只是没有说话人标注。
struct MixedRecordingResult {
    let movieURL: URL
    let localTrackURL: URL?
    let remoteTrackURL: URL?
}

/// 已经归一化成 16 kHz 单声道、可以直接送进 whisper 的两路音频。
///
/// **两路必须同时存在**。只有一路时宁可不做说话人标注：麦克风那一路本来就混着
/// 外放出来的对方声音，只按它标"我方"会把对方说的话算成我方 —— 那是看不见的数据损坏。
struct DualTrackInput {
    let local: URL
    let remote: URL
}

/// 把一路 `SCStreamOutput` 接到 `AudioTrackRecorder` 上的薄适配层。
///
/// `AudioTrackRecorder` 刻意**不认识 ScreenCaptureKit**：它只负责"给我 PCM，我落文件"。
/// 于是它的搬运逻辑可以用手工拼出来的 `CMSampleBuffer` 单测（见 `AudioTrackRecorderTests`）——
/// 否则录音这条链路上就没有任何一处是能自动验证的。
private final class TrackStreamOutput: NSObject, SCStreamOutput {
    private let recorder: AudioTrackRecorder
    private let outputType: SCStreamOutputType

    init(recorder: AudioTrackRecorder, outputType: SCStreamOutputType) {
        self.recorder = recorder
        self.outputType = outputType
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // 同一个 `SCStream` 上挂了多个 output，回调按 output 分别来。
        // 类型对不上就是别人的样本，扔掉。
        guard type == outputType else { return }
        recorder.append(sampleBuffer)
    }
}

@MainActor
final class MixedRecordingSession: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private let movieURL: URL
    private let localTrackURL: URL?
    private let remoteTrackURL: URL?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var localRecorder: AudioTrackRecorder?
    private var remoteRecorder: AudioTrackRecorder?
    /// `SCStream` 不持有 output，得自己留着，否则挂上去就没了。
    private var trackOutputs: [TrackStreamOutput] = []
    private var didStartRecording = false
    private var didFinishRecording = false
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<MixedRecordingResult, Error>?
    private var stopError: Error?

    /// 两路音频**共用一个串行队列**：写文件的顺序就是采样顺序，两路之间也不会互相打架。
    private static let sampleQueue = DispatchQueue(
        label: "com.qingmeng.meetingscribe.audio-tracks"
    )

    /// 双声道两路是**可选**的：不给 URL 就退化成"只录 `.mov`"，也就是改动前的行为。
    /// 这条降级路径是故意留的 —— 说话人标注失败绝不能让录音本身失败。
    init(movieURL: URL, localTrackURL: URL? = nil, remoteTrackURL: URL? = nil) {
        self.movieURL = movieURL
        self.localTrackURL = localTrackURL
        self.remoteTrackURL = remoteTrackURL
    }

    func start() async throws {
        let granted = await Self.requestScreenAccess()
        guard granted else {
            throw PipelineError.transcriptionFailed(
                "未获得屏幕与系统音频录制权限。如果刚刚允许，请完全退出并重新打开 MeetingScribe 后再试。"
            )
        }

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

        // 双声道（P2-2a）：在**同一个** `SCStream` 上再挂两个 output。
        //
        // macOS 15 的 ScreenCaptureKit 本来就把两路分开投递：麦克风走 `.microphone`、
        // 系统声走 `.audio`。而"同一个 stream = 同一个时钟"，两路的时间戳天然对齐 ——
        // 这里不存在"两个独立采集源各自跑时钟、录到半小时就对不齐"的老问题。
        //
        // ⚠️ 加不上**不抛**：少一路就少一个说话人标注，录音本身照旧。
        if let localTrackURL {
            localRecorder = attachTrack(to: stream, url: localTrackURL, type: .microphone)
        }
        if let remoteTrackURL {
            remoteRecorder = attachTrack(to: stream, url: remoteTrackURL, type: .audio)
        }

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

    func stop() async throws -> MixedRecordingResult {
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

    /// 把一路音频接到 stream 上。失败返回 nil（这一路就没有）。
    private func attachTrack(
        to stream: SCStream,
        url: URL,
        type: SCStreamOutputType
    ) -> AudioTrackRecorder? {
        let recorder = AudioTrackRecorder(url: url)
        let output = TrackStreamOutput(recorder: recorder, outputType: type)
        do {
            try stream.addStreamOutput(output, type: type, sampleHandlerQueue: Self.sampleQueue)
        } catch {
            // 比如系统版本不认识 `.microphone`。少一路不算错，录音继续。
            return nil
        }
        trackOutputs.append(output)
        return recorder
    }

    /// 收尾两路文件。
    private func finishTrackRecorders() {
        // 先把采样队列排空：`finish()` 之后进来的样本会被丢掉，
        // 不排空的话最后几十毫秒的音频会**静默**消失。
        Self.sampleQueue.sync {}
        localRecorder?.finish()
        remoteRecorder?.finish()
    }

    private func makeResult() -> MixedRecordingResult {
        MixedRecordingResult(
            movieURL: movieURL,
            // 没写出内容的轨道当作"没有这一路"，别把一个 0 字节的文件交出去。
            localTrackURL: (localRecorder?.didWriteAudio ?? false) ? localTrackURL : nil,
            remoteTrackURL: (remoteRecorder?.didWriteAudio ?? false) ? remoteTrackURL : nil
        )
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.didStartRecording = true
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.didFinishRecording = true
            self?.finishStopIfPossible()
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor [weak self] in
            self?.stopError = error
            self?.finishStopIfPossible()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.stopError = error
            self?.finishStopIfPossible()
        }
    }

    private func finishStopIfPossible() {
        guard stopRequested else { return }

        if let error = stopError {
            finishTrackRecorders()
            stopContinuation?.resume(throwing: error)
            stopContinuation = nil
            cleanup()
            return
        }

        guard didFinishRecording else { return }
        finishTrackRecorders()
        stopContinuation?.resume(returning: makeResult())
        stopContinuation = nil
        cleanup()
    }

    private func cleanup() {
        stream = nil
        recordingOutput = nil
        trackOutputs.removeAll()
        localRecorder = nil
        remoteRecorder = nil
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

/// 读一段音频的峰值电平，用来判断某一路是不是**全程静音**（P2-2a）。
struct AudioLevelProbe {
    /// 低于它就算静音（约 -40 dBFS）。
    static let silenceThreshold: Float = 0.01

    /// 这一路有没有超过静音线的地方。
    ///
    /// 为什么值得单独做这一件事：一路全程静音的通道送进 whisper，不但白花一半时间，
    /// 还会在静音上**幻觉出一整段话**（whisper 的经典毛病）—— 那会把一整段虚构内容
    /// 写进逐字稿，比"不转这一路"糟得多。所以"跳过静音的一路"既是省时间，也是防幻觉。
    func hasAudibleSignal(at url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw PipelineError.audioDurationUnavailable
        }

        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }

            let frames = Int(buffer.frameLength)
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for index in 0..<frames where abs(samples[index]) > Self.silenceThreshold {
                    return true
                }
            }
        }
        return false
    }
}

actor WhisperCLIRunner {
    private let processRunner = LocalProcessRunner()

    /// 起始提示词（initial prompt）。它会被当成「上一句」喂给解码器。
    ///
    /// **旧结论已推翻**：这里原来写的是「只说语言和场合，不猜话题」，
    /// 怕猜偏了把无关词汇带进结果。2026-09-13 实测是反的 ——
    /// 把**术语表**拼进 prompt（配合 `--carry-initial-prompt`）能明显压低专名误听
    /// （客户→课考、拜访→败网 这类），专名错词几乎归零，还顺手抬了断句质量。
    ///
    /// 仍然坚持的那条边界是：**只放术语，不放"这场会在讲什么"**。
    /// 术语是词表，话题是判断，后者猜错会污染整场。
    ///
    /// ⚠️ 内容**不再写死在这里**：由设置页的「识别术语表」经 `Glossary.whisperInitialPrompt()`
    /// 拼出来（P1-3 / 2D）。同一个词表还供后处理替换表和整理 prompt 使用，三处一份数据。
    /// 这个词只对 whisper 生效，后两处各有各的形态。
    private static func promptArguments(_ initialPrompt: String) -> [String] {
        // 空提示词就两个参数都不给：`--carry-initial-prompt` 单挂着没有意义。
        guard !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return [
            // 每个解码窗口都从这段提示词起步。不加这个开关的话，术语表只影响
            // 每块音频的前几段，越往后越"忘"。
            "--carry-initial-prompt",
            "--prompt", initialPrompt
        ]
    }

    /// 这些是每次转写都一样的参数，单独抽出来方便在 GPU 失败后用 CPU 重跑。
    private static func baseArguments(
        modelURL: URL,
        audioURL: URL,
        language: String,
        outputPrefix: URL,
        offset: TimeInterval,
        duration: TimeInterval?,
        initialPrompt: String
    ) -> [String] {
        var arguments = [
            "-m", modelURL.path,
            "-f", audioURL.path,
            "-l", language,
            "-t", "\(min(8, max(4, ProcessInfo.processInfo.activeProcessorCount - 2)))",
            // 束搜索。whisper.cpp 默认是贪心解码，中文里同音误判很多
            //（客户→课考、拜访→败网、罐头→灌投 这类），束宽 5 能明显压下去。
            "-bs", "5",
            "-oj",
            "-ojf",
            "-np",
            // 抑制非语音 token。whisper 会给 `[BLANK_AUDIO]`、`♪♪`、`(掌声)` 这类
            // 单独占一段，而它们**不带任何标点** —— 实测「没有标点的段」里有相当一部分
            // 就是它们，把断句合格率白白拉低。抑制掉之后有标点的段占比明显回升。
            "-sns",
            "-of", outputPrefix.path
        ]
        arguments.append(contentsOf: promptArguments(initialPrompt))

        if offset > 0 {
            arguments.append(contentsOf: ["-ot", "\(Int((offset * 1000).rounded()))"])
        }
        if let duration, duration > 0 {
            arguments.append(contentsOf: ["-d", "\(Int((duration * 1000).rounded()))"])
        }
        return arguments
    }

    func transcribe(
        audioURL: URL,
        cliURL: URL,
        modelURL: URL,
        outputPrefix: URL,
        offset: TimeInterval = 0,
        duration: TimeInterval? = nil,
        language: String = "zh",
        /// 起始提示词。**刻意不给默认值**：出厂词表和用户词表的差别只有用户自己知道，
        /// 一个"忘了传就用出厂"的默认值会静默把用户设置的术语表丢掉，
        /// 而现象是"转写结果看着正常，只是错词还是老样子"—— 没人能看出是这里出的问题。
        initialPrompt: String
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

        // 走 GPU。本机实测 Metal 可用，100 秒音频 4 秒转完（CPU 要 7 秒）。
        var arguments = Self.baseArguments(
            modelURL: modelURL,
            audioURL: audioURL,
            language: language,
            outputPrefix: outputPrefix,
            offset: offset,
            duration: duration,
            initialPrompt: initialPrompt
        )
        let environment = ["DYLD_LIBRARY_PATH": cliURL.deletingLastPathComponent().path]
        var result = try await processRunner.run(
            executableURL: cliURL,
            arguments: arguments,
            environment: environment
        )

        // ggml-metal 在这个项目里崩过，所以真出问题时退一步用纯 CPU 再跑一次，
        // 而不是让整场录音的转写直接失败。
        if result.status != 0 && !Task.isCancelled {
            try? FileManager.default.removeItem(at: jsonURL)
            arguments.append("-ng")
            result = try await processRunner.run(
                executableURL: cliURL,
                arguments: arguments,
                environment: environment
            )
        }

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
