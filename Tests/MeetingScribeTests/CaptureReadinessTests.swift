import Foundation
import XCTest
@testable import MeetingScribe

/// 阶段 1-2 的单测：录音权限的两道门。
///
/// 判据（`docs/升级计划-按状态空间重排.md` 1-2）：
/// **四个组合（两权限各有 / 各无）都有对应的界面状态**；
/// 缺权限时给的是**可执行的下一步**，不是一句错误。
///
/// 注意：这里**不触碰真实权限**（不调 `refreshCapturePermissions()`、
/// 不调 `CGRequestScreenCaptureAccess()`），只测判定与文案 —— 真实权限是机器状态，
/// 不能进单测。
final class CaptureReadinessTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureReadinessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    // MARK: - 四个组合

    func testBothGrantedIsReadyAndSaysNothing() {
        let readiness = CaptureReadiness.ready
        XCTAssertTrue(readiness.canStartRecording)
        XCTAssertNil(readiness.blockingMessage, "都齐了就不该拦")
        XCTAssertNil(readiness.microphoneCaveat, "都齐了就没有旁注可说")
    }

    func testMissingSystemAudioBlocksAndExplainsTheRestart() {
        let readiness = CaptureReadiness.missingSystemAudio(microphone: .granted)
        XCTAssertFalse(readiness.canStartRecording, "缺系统音频就是录不了")

        let message = readiness.blockingMessage ?? ""
        XCTAssertFalse(message.isEmpty, "拦下来时必须给一句说明")
        XCTAssertTrue(message.contains("屏幕与系统音频"), "要点名是哪一道权限")
        XCTAssertTrue(
            message.contains("完全退出"),
            "必须把 macOS 的『授权后要完全重开』讲成一句可操作的话，而不是'失败了'"
        )
        XCTAssertNotNil(
            readiness.microphoneCaveat,
            "系统音频缺失时，麦克风的状态也要一并说清"
        )
    }

    func testMissingMicrophoneOnlyStillAllowsRecordingButWarns() {
        let readiness = CaptureReadiness.missingMicrophoneOnly
        XCTAssertTrue(readiness.canStartRecording, "缺麦克风不该拦住录音 —— 录得了，只是没有说话人标注")
        XCTAssertNil(readiness.blockingMessage, "不该给一句拦截文案")

        let caveat = readiness.microphoneCaveat ?? ""
        XCTAssertTrue(caveat.contains("我方"), "要说清后果是『不区分我方 / 对方』")
        XCTAssertTrue(caveat.contains("照常"), "也要说清录音本身不受影响")
    }

    func testMissingBothFallsIntoTheSystemAudioBranch() {
        let readiness = CaptureReadiness.missingSystemAudio(microphone: .denied)
        XCTAssertFalse(readiness.canStartRecording, "两样都缺时先解决拦住录音的那一道")
        XCTAssertNotNil(readiness.blockingMessage)
        XCTAssertNotNil(readiness.microphoneCaveat)
    }

    // MARK: - 三道门的状态文案

    func testPermissionLabelsAreDistinct() {
        XCTAssertEqual(ScreenCapturePermission.granted.label, "已授权")
        XCTAssertEqual(ScreenCapturePermission.denied.label, "未授权")

        // 麦克风三种状态必须能分开：「未授权」不会再弹窗，「尚未询问」会弹一次，
        // 处置完全不同 —— 塌成一句就等于把用户引向错误的下一步。
        XCTAssertEqual(MicrophonePermission.granted.label, "已授权")
        XCTAssertEqual(MicrophonePermission.denied.label, "未授权")
        XCTAssertEqual(MicrophonePermission.notDetermined.label, "尚未询问")
        XCTAssertEqual(
            Set([
                MicrophonePermission.granted.label,
                MicrophonePermission.denied.label,
                MicrophonePermission.notDetermined.label
            ]).count,
            3
        )
    }

    // MARK: - store 层的映射

    @MainActor
    func testStoreReadinessFollowsTheTwoPermissions() throws {
        let store = MeetingStore(storage: SessionStorage(rootURL: root))

        store.screenCapturePermission = .granted
        store.microphonePermission = .granted
        XCTAssertEqual(store.captureReadiness, .ready)

        store.microphonePermission = .notDetermined
        XCTAssertEqual(
            store.captureReadiness,
            .missingMicrophoneOnly,
            "缺麦克风只是降级，不是拦路"
        )

        store.screenCapturePermission = .denied
        XCTAssertEqual(
            store.captureReadiness,
            .missingSystemAudio(microphone: .notDetermined),
            "缺系统音频才是拦住录音的那一道"
        )
        XCTAssertFalse(store.captureReadiness.canStartRecording)
    }
}
