// 双声道投递探针（P2-2a 排查工具）
//
// 用来回答一个问题：**ScreenCaptureKit 到底会不会把麦克风与系统声分成两路投递？**
//
// 用法（不需要跑 App，也不需要真的说话 —— 静音也会持续投递样本）：
//   xcrun swiftc -O Scripts/probe_dual_track_delivery.swift -o /tmp/dualprobe
//   ( say -v Ting-Ting "测试" & ) ; /tmp/dualprobe
//
// 2026-09-14 首次运行结果（macOS 15 / Apple Silicon）：两路都成功挂上，8 秒内
// 麦克风 795 样本、系统声 675 样本，格式均为 lpcm —— 即采集层从来没有问题，
// 当时「没有说话人标签」的真因是调用方漏传了两路 URL（见 §24.10）。

import Foundation
import ScreenCaptureKit
import CoreMedia

final class Counter: NSObject, SCStreamOutput {
    let label: String
    private(set) var samples = 0
    private(set) var frames = 0
    private var fourCC: String?

    init(_ label: String) { self.label = label }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        if let fd = CMSampleBufferGetFormatDescription(sb) {
            let sub = CMFormatDescriptionGetMediaSubType(fd)
            if fourCC == nil {
                let bytes = [UInt8((sub >> 24) & 255), UInt8((sub >> 16) & 255), UInt8((sub >> 8) & 255), UInt8(sub & 255)]
                fourCC = String(bytes: bytes, encoding: .ascii)
            }
        }
        samples += 1
        frames += CMSampleBufferGetNumSamples(sb)
    }

    var summary: String {
        "\(label): \(samples) 个样本 / \(frames) 帧 / 格式 \(fourCC ?? "无")"
    }
}

let seconds = 8.0
print("== 双声道投递探针 ==")

let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            print("✗ 找不到显示器"); exitCode = 1; sem.signal(); return
        }
        let excluded = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        print("captureMicrophone 已设置 = \(config.captureMicrophone)")

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let mic = Counter("我方（麦克风 / .microphone）")
        let sys = Counter("对方（系统声 / .audio）")

        do {
            try stream.addStreamOutput(mic, type: .microphone, sampleHandlerQueue: .global())
            print("✓ addStreamOutput(.microphone) 成功")
        } catch {
            print("✗ addStreamOutput(.microphone) 失败：\(error)")
            exitCode = 2
        }
        do {
            try stream.addStreamOutput(sys, type: .audio, sampleHandlerQueue: .global())
            print("✓ addStreamOutput(.audio) 成功")
        } catch {
            print("✗ addStreamOutput(.audio) 失败：\(error)")
            exitCode = 3
        }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        print("采集已启动，跑 \(Int(seconds)) 秒…")

        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            stream.stopCapture { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }

        print("--- 结果 ---")
        print(mic.summary)
        print(sys.summary)
        print("判定：我方投递 = \(mic.samples > 0 ? "有" : "无")；对方投递 = \(sys.samples > 0 ? "有" : "无")")
    } catch {
        print("✗ 整体失败：\(error)")
        exitCode = 4
    }
    sem.signal()
}

sem.wait()
exit(exitCode)
