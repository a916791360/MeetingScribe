import Foundation
import XCTest
@testable import MeetingScribe

/// 双声道两路的命名约定（P2-2a）。
///
/// 这些断言看着"只是在测几个字符串"，但每一条都对应一次**静默**事故：
/// 名字一旦漂移，不会报错，只会让某一环找不到文件，然后安静地退回单路 ——
/// 用户看到的是一份"正常但永远没有说话人标签"的逐字稿（2026-09-14 实际发生过）。
final class DualTrackPathsTests: XCTestCase {
    func testNamesArePinnedToTheirValues() {
        // 钉住字面量：这几个名字会写进 session.json，改了就再也找不回历史会话的两路音频。
        XCTAssertEqual(DualTrackPaths.localCaptureName, "local.caf")
        XCTAssertEqual(DualTrackPaths.remoteCaptureName, "remote.caf")
        XCTAssertEqual(DualTrackPaths.localNormalizedName, "local.wav")
        XCTAssertEqual(DualTrackPaths.remoteNormalizedName, "remote.wav")
    }

    func testCaptureNamesAreNotNormalizedNames() {
        // 归一化是"读 capture、写 normalized"。同名会让 afconvert 的输入输出撞在一个文件上：
        // 要么原地截断（数据没了），要么直接报错。两种都不是我们想要的。
        XCTAssertNotEqual(DualTrackPaths.localCaptureName, DualTrackPaths.localNormalizedName)
        XCTAssertNotEqual(DualTrackPaths.remoteCaptureName, DualTrackPaths.remoteNormalizedName)
    }

    func testTheFourNamesAreAllDistinct() {
        // 两路之间也不能撞：撞了就是"我方"那一路覆盖"对方"那一路，
        // 结果是一份只有一个人的逐字稿，且完全看不出哪里不对。
        let names: Set<String> = [
            DualTrackPaths.localCaptureName,
            DualTrackPaths.remoteCaptureName,
            DualTrackPaths.localNormalizedName,
            DualTrackPaths.remoteNormalizedName
        ]
        XCTAssertEqual(names.count, 4)
    }

    func testCaptureFileTypesMatchWhatTheRecorderWrites() {
        // `AudioTrackRecorder` 用的是 `AVAudioFile`，容器格式由扩展名决定。
        // 原始录音必须是无长度上限的 `.caf`；交给 whisper 的必须是 `.wav`。
        XCTAssertEqual((DualTrackPaths.localCaptureName as NSString).pathExtension, "caf")
        XCTAssertEqual((DualTrackPaths.remoteCaptureName as NSString).pathExtension, "caf")
        XCTAssertEqual((DualTrackPaths.localNormalizedName as NSString).pathExtension, "wav")
        XCTAssertEqual((DualTrackPaths.remoteNormalizedName as NSString).pathExtension, "wav")
    }

    func testCaptureURLsLandInTheGivenFolderWithTheCaptureNames() {
        let folder = URL(fileURLWithPath: "/tmp/MeetingScribe-dual-paths-test", isDirectory: true)
        let urls = DualTrackPaths.captureURLs(in: folder)

        XCTAssertEqual(urls.local.deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(urls.remote.deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(urls.local.lastPathComponent, DualTrackPaths.localCaptureName)
        XCTAssertEqual(urls.remote.lastPathComponent, DualTrackPaths.remoteCaptureName)
        XCTAssertNotEqual(urls.local, urls.remote)
    }

    func testCaptureAndNormalizedTargetsNeverCollideInOneFolder() {
        // 把两个目标集合摆在一起看：同一个会话目录里，四个位置必须互不相同。
        let folder = URL(fileURLWithPath: "/tmp/MeetingScribe-dual-paths-test", isDirectory: true)
        let capture = DualTrackPaths.captureURLs(in: folder)
        let normalized = [
            folder.appendingPathComponent(DualTrackPaths.localNormalizedName),
            folder.appendingPathComponent(DualTrackPaths.remoteNormalizedName)
        ]

        XCTAssertFalse(normalized.contains(capture.local))
        XCTAssertFalse(normalized.contains(capture.remote))
    }
}
