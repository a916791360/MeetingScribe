import AVFoundation
import CoreMedia
import Foundation

/// 把一路 `SCStreamOutput` 丢过来的音频样本落成一个音频文件（P2-2a 双声道）。
///
/// ## 为什么"能失败就失败，绝不抛"
///
/// 这一路是**附加**的：录音本身仍然靠 `SCRecordingOutput` 落的那支 `.mov`。
/// 双声道只是让逐字稿多一个说话人标注。所以写文件这件事**任何一步出问题都只能
/// 安静地放弃这一路**，绝不能让整场录音失败 —— 用户宁可要一份标不出说话人的
/// 逐字稿，也不要"录到一半报错了"。
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

    init(url: URL) {
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
        if let failure { return "失败：\(failure)" }
        if framesWritten == 0 { return "一个样本都没写出来（0 帧）" }
        return "已写入 \(framesWritten) 帧"
    }

    var outputURL: URL { url }

    /// `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)` 的直通口。
    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished, failure == nil else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        guard let format = Self.format(of: sampleBuffer) else {
            failure = "音频样本不是标准的线性 PCM 格式。"
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

        switch Self.write(sampleBuffer: sampleBuffer, format: format, into: target) {
        case .success(let frames):
            framesWritten += frames
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

    private enum WriteOutcome {
        case success(AVAudioFramePosition)
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
        return .success(AVAudioFramePosition(buffer.frameLength))
    }

    /// 从样本里读出标准格式。**不是标准格式就返回 nil**：宁可放弃这一路，
    /// 也不要为了兼容它去手写格式转换（那正是会静默产出噪音的地方）。
    private static func format(of sampleBuffer: CMSampleBuffer) -> AVAudioFormat? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }
        guard let format = AVAudioFormat(streamDescription: asbd), format.isStandard else {
            return nil
        }
        return format
    }
}
