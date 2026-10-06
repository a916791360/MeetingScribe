import AVFoundation
import CoreMedia
import Foundation

/// 把一路 `SCStreamOutput` 丢过来的音频样本落成一个音频文件（P2-2a 双声道）。
///
/// 两路音频也是原件：停止采集后由AudioOnlyRecordingAssembler生成纯音频回退文件。
/// 一路写入失败会留下原因和已写文件；不把失败轨道用于完整说话人转写。
///
/// 同理，**格式一旦中途变了就立刻停手**（`failureReason` 记下原因，不再写一个字节）：
/// 把两种格式混进同一个文件，得到的是一段能播放、但内容是噪音的音频 ——
/// 那属于本项目最怕的"看不见的数据损坏"。
///
/// ## 线程
///
/// `append` 由 ScreenCaptureKit 的采样回调队列调用，`didWriteAudio` / `finish`
/// 由主线程调用，所以状态一律过锁。这个类很小，锁不会成为瓶颈（一路音频每秒
/// 也就几十个样本缓冲）。
final class AudioTrackRecorder: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var failure: String?
    private var isFinished = false
    /// 这一路第一次见到的样本格式（诊断用）。`nil` = 一个样本都没来过。
    private var sourceFormat: String?
    private var timelineOrigin: CMTime?
    private var measuredLevel: Double = 0
    private var measuredAt = Date.distantPast

    init(url: URL, timelineOrigin: CMTime? = nil) {
        self.timelineOrigin = timelineOrigin
        self.url = url
    }

    /// 这一路到底写进去东西没有。**"全程静音"也算法** —— 静音是有效数据
    /// （它证明这一路真的在采），决定要不要跳过转写的是别处的电平判断。
    var didWriteAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return framesWritten > 0
    }

    /// 这一路为什么废了（诊断用，不给用户看）。nil = 一切正常。
    var failureReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// 诊断用：一共写进去多少帧（`0` = 从头到尾一个样本都没写出来）。
    ///
    /// 这个数和 `failureReason` 一起进系统日志 —— 双声道出问题时，
    /// "是没挂上采样输出、还是挂上了但一个样本都没来"，只能靠它们分辨。
    var frameCount: AVAudioFramePosition {
        lock.lock()
        defer { lock.unlock() }
        return framesWritten
    }

    /// 一句话讲清这一路的状态，给日志用。
    var diagnosticSummary: String {
        lock.lock()
        defer { lock.unlock() }
        let format = sourceFormat.map { "，首个样本 \($0)" } ?? ""
        if let failure { return "失败：\(failure)\(format)" }
        if framesWritten == 0 { return "一个样本都没写出来（0 帧）\(format)" }
        return "已写入 \(framesWritten) 帧\(format)"
    }

    var level: Double {
        lock.withLock { failure == nil && Date().timeIntervalSince(measuredAt) < 1 ? measuredLevel : 0 }
    }

    var isUsable: Bool {
        lock.withLock { framesWritten > 0 && failure == nil }
    }

    var outputURL: URL { url }

    /// `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)` 的直通口。
    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished, failure == nil else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        let incomingFormat = Self.describe(sampleBuffer)
        if sourceFormat == nil {
            sourceFormat = incomingFormat
        }

        guard let format = Self.format(of: sampleBuffer) else {
            failure = "音频样本不是可落盘的线性 PCM 格式（首个样本：\(incomingFormat)）。"
            return
        }

        if let fileFormat, fileFormat != format {
            failure = "同一路音频中途换了格式，已停止写入（继续写会得到一段噪音）。"
            return
        }

        if file == nil {
            do {
                file = try AVAudioFile(forWriting: url, settings: format.settings)
                fileFormat = format
            } catch {
                failure = "创建音频文件失败：\(error.localizedDescription)"
                return
            }
        }

        guard let target = file else {
            failure = "音频文件没有准备好。"
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if timelineOrigin == nil { timelineOrigin = pts }
        guard pts.isNumeric, let origin = timelineOrigin, origin.isNumeric else {
            failure = "音频时间戳无效，已退回混合原件。"; return
        }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(pts, origin))
        guard seconds.isFinite, seconds >= -0.001, seconds <= 3 * 60 * 60 + 60 else {
            failure = "音频时间戳超出录音范围，已退回混合原件。"; return
        }
        let position = AVAudioFramePosition((max(0, seconds) * format.sampleRate).rounded())
        if position < framesWritten - 1 {
            failure = "音频时间戳重叠或倒退，已退回混合原件。"; return
        }
        do {
            try Self.writeSilence(frames: max(0, position - framesWritten), format: format, into: target)
            framesWritten = max(framesWritten, position)
        } catch { failure = "补齐音频间隔失败：\(error.localizedDescription)"; return }

        switch Self.write(sampleBuffer: sampleBuffer, format: format, into: target) {
        case .success(let frames, let level):
            framesWritten += frames
            measuredLevel = level
            measuredAt = Date()
        case .failure(let message):
            failure = message
        }
    }

    /// 收尾：关掉文件句柄。没写出内容的会把空文件删掉，免得留下一个 0 字节的
    /// 干扰物（后面的静音/存在性判断都得绕开它）。
    func finish() {
        lock.lock()
        defer { lock.unlock() }

        isFinished = true
        file = nil
        fileFormat = nil

        if framesWritten == 0, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 样本搬运

    private static func writeSilence(frames: AVAudioFramePosition, format: AVAudioFormat, into file: AVAudioFile) throws {
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw PipelineError.transcriptionFailed("无法创建静音缓冲。")
        }
        var remaining = frames
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(8192, remaining))
            for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
            }
            try file.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private enum WriteOutcome {
        case success(AVAudioFramePosition, Double)
        case failure(String)
    }

    private static func write(
        sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat,
        into file: AVAudioFile
    ) -> WriteOutcome {
        var neededSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, neededSize > 0 else {
            return .failure("取不到音频缓冲区的尺寸。")
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: neededSize, alignment: 16)
        defer { raw.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: raw.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: neededSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard listStatus == noErr else {
            return .failure("取不到音频缓冲区。")
        }

        // `blockBuffer` 必须活到写完为止 —— 非交错格式下缓冲区里的 mData 指向
        // 它持有的内存。这里显式引用一下，别让编译器以为它没用就提前放掉。
        guard blockBuffer != nil else {
            return .failure("音频缓冲区的持有块缺失。")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: raw.assumingMemoryBound(to: AudioBufferList.self)
        ) else {
            return .failure("样本格式与音频缓冲不匹配。")
        }
        buffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))

        do {
            try file.write(from: buffer)
        } catch {
            return .failure("写入音频文件失败：\(error.localizedDescription)")
        }
        var squares = 0.0
        var samples = 0
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audio.mData else { continue }
            if format.commonFormat == .pcmFormatFloat32 {
                let count = Int(audio.mDataByteSize) / MemoryLayout<Float>.size
                let values = data.assumingMemoryBound(to: Float.self)
                for i in 0..<count { let value = Double(values[i]); if value.isFinite { squares += value * value }; samples += 1 }
            } else if format.commonFormat == .pcmFormatInt16 {
                let count = Int(audio.mDataByteSize) / MemoryLayout<Int16>.size
                let values = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<count { let value = Double(values[i]) / 32768; squares += value * value; samples += 1 }
            }
        }
        let rms = samples > 0 ? sqrt(squares / Double(samples)) : 0
        let level = rms > 0 ? min(1, max(0, (20 * log10(rms) + 60) / 60)) : 0
        return .success(AVAudioFramePosition(buffer.frameLength), level)
    }

    /// 从样本里读出格式。**只认线性 PCM，但不再要求 `AVAudioFormat.isStandard`。**
    ///
    /// ⚠️ 这条 `isStandard` 判断是 2026-09-14 那场"永远没有说话人标签"的**真凶**：
    /// 强化版探针（`Scripts/probe_dual_track_delivery.swift`）实测出两路的格式并不对称 ——
    ///
    /// | 路 | 实测格式 | `isStandard` |
    /// |---|---|---|
    /// | `.microphone`（我方） | 48 kHz / 1 声道 / **Float32 交错** | **false** → 被这一句丢掉 |
    /// | `.audio`（对方） | 16 kHz / 1 声道 / Float32 非交错 | true → 一直正常 |
    ///
    /// `AVAudioFormat.isStandard` 只认「非交错 Float32」与「交错 Int16/Int32」，
    /// **交错的 Float32 它判成非标准** —— 于是麦克风那一路 575 个样本、294400 帧
    /// 全被拒掉，`local.caf` 永远是 0 字节（随后被 `finish()` 删掉），
    /// 表现和"系统根本不支持麦克风分离"**一模一样**。这个不对称正是线索。
    ///
    /// 现在只要求「线性 PCM + 采样率/声道数/每帧字节数都合理」。落盘用**源格式原样**写
    /// （`AVAudioFile(forWriting:settings:)` 认这套 settings，探针实测 48 kHz 交错 Float32
    /// 也能一路写出去），格式归一化交给后面统一的 afconvert。
    private static func format(of sampleBuffer: CMSampleBuffer) -> AVAudioFormat? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              asbd.pointee.mSampleRate > 0,
              asbd.pointee.mChannelsPerFrame > 0,
              asbd.pointee.mBytesPerFrame > 0 else {
            return nil
        }
        return AVAudioFormat(streamDescription: asbd)
    }

    /// 一句话描述这一路样本的格式，**只进日志**。
    ///
    /// 为什么非要记：上面那场事故里日志只写了"我方 0 帧"，而"0 帧"同时对应
    /// 「系统没投递样本（权限）」与「投递了但格式被我们拒了」两种完全不同的病因 ——
    /// 只有把格式打出来，才不用再让人多录一次。所以判废时**必须连格式一起报**。
    private static func describe(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return "格式未知"
        }
        let value = asbd.pointee
        let flags = value.mFormatFlags
        let kind: String
        if flags & kAudioFormatFlagIsFloat != 0 {
            kind = "Float32"
        } else if flags & kAudioFormatFlagIsSignedInteger != 0 {
            kind = "Int\(value.mBitsPerChannel)"
        } else {
            kind = "\(value.mBitsPerChannel) 位"
        }
        let layout = flags & kAudioFormatFlagIsNonInterleaved != 0 ? "非交错" : "交错"
        return "\(Int(value.mSampleRate)) Hz / \(value.mChannelsPerFrame) 声道 / \(kind) / \(layout)"
    }
}
