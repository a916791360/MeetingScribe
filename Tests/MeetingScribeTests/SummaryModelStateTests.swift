import Foundation
import XCTest
@testable import MeetingScribe

/// 阶段 1-1 的单测：整理模型连接状态机。
///
/// 判据（`docs/升级计划-按状态空间重排.md`）：**9 种语义各自有独立 case 与独立文案**。
/// 所以这里逐个 case 钉住 `message` / `tone` / `showsMessage` / `isBusy`，
/// 不让它们再塌回一根 `String`。
final class SummaryModelStateTests: XCTestCase {

    // MARK: - 每个 case 独立渲染

    func testIdleSaysNothing() {
        let state = SummaryModelTestState.idle
        XCTAssertFalse(state.showsMessage, "idle 不该在界面上占位")
        XCTAssertEqual(state.message, "")
        XCTAssertEqual(state.tone, .neutral)
        XCTAssertFalse(state.isBusy)
    }

    func testConnectingIsNeutralAndBusy() {
        let state = SummaryModelTestState.connecting
        XCTAssertTrue(state.showsMessage)
        XCTAssertTrue(state.isBusy, "连接中要能禁掉按钮")
        XCTAssertEqual(state.tone, .neutral)
        XCTAssertFalse(state.message.isEmpty)
    }

    func testKeySaveFailedIsDangerAndNotBusy() {
        let state = SummaryModelTestState.keySaveFailed
        XCTAssertEqual(state.tone, .danger)
        XCTAssertFalse(state.isBusy, "保存失败已经结束，不该还在转圈")
        XCTAssertTrue(state.message.contains("保存失败"))
    }

    func testLoadedDistinguishesSelectedFromUnselected() {
        let unselected = SummaryModelTestState.loaded(count: 7, selected: nil)
        XCTAssertEqual(unselected.tone, .success)
        XCTAssertTrue(unselected.message.contains("7"))
        XCTAssertTrue(unselected.message.contains("请选择"), "还没选时要明确让用户选")

        let selected = SummaryModelTestState.loaded(count: 7, selected: "gpt-6-astra")
        XCTAssertTrue(selected.message.contains("7"))
        XCTAssertFalse(
            selected.message.contains("请选择"),
            "已经有选定了就不该再催一次"
        )
    }

    func testNoListTellsUserToFillManually() {
        let state = SummaryModelTestState.noList
        XCTAssertEqual(state.tone, .neutral, "连接是通的，不该报警")
        XCTAssertTrue(state.message.contains("手动"))
    }

    func testTestingNamesTheModelAndIsBusy() {
        let state = SummaryModelTestState.testing(model: "moonshot-v1-8k")
        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.message.contains("moonshot-v1-8k"))
    }

    func testAvailableNamesTheModel() {
        let state = SummaryModelTestState.available(model: "qwen-plus")
        XCTAssertEqual(state.tone, .success)
        XCTAssertTrue(state.message.contains("qwen-plus"))
    }

    func testSelectedSaysItWillBeUsed() {
        let state = SummaryModelTestState.selected(model: "deepseek-v4")
        XCTAssertEqual(state.tone, .success)
        XCTAssertTrue(state.message.contains("deepseek-v4"))
        XCTAssertTrue(state.message.contains("会后整理"))
    }

    // MARK: - 失败态：四类各自答「下一步做什么」

    func testEveryFailureReasonHasTitleAndNextStep() {
        let reasons: [SummaryModelFailure] = [.auth, .endpoint, .network, .server]
        for reason in reasons {
            XCTAssertFalse(reason.title.isEmpty, "\(reason) 缺 title")
            XCTAssertFalse(reason.nextStep.isEmpty, "\(reason) 缺 nextStep")
            XCTAssertNotEqual(reason.title, reason.nextStep)
        }
        XCTAssertEqual(
            Set(reasons.map(\.title)).count,
            reasons.count,
            "四类的 title 必须互不相同，否则又塌回一条错误串"
        )
        XCTAssertEqual(
            Set(reasons.map(\.nextStep)).count,
            reasons.count,
            "四类的下一步必须互不相同，否则用户还是不知道该改什么"
        )
    }

    func testFailedStateCarriesReasonAndStaysActionable() {
        let state = SummaryModelTestState.failed(.auth)
        XCTAssertEqual(state.tone, .danger)
        XCTAssertTrue(state.message.contains(SummaryModelFailure.auth.title))
        XCTAssertTrue(
            state.message.contains(SummaryModelFailure.auth.nextStep),
            "失败态必须把「下一步做什么」一起说清楚"
        )
    }

    func testFailureClassificationMapsEngineErrors() {
        XCTAssertEqual(SummaryModelFailure.classify(SummaryEngineError.missingAPIKey), .auth)
        XCTAssertEqual(SummaryModelFailure.classify(SummaryEngineError.invalidEndpoint), .endpoint)
        XCTAssertEqual(SummaryModelFailure.classify(SummaryEngineError.networkFailed("boom")), .network)
        XCTAssertEqual(SummaryModelFailure.classify(SummaryEngineError.requestFailed(401, "denied")), .auth)
        XCTAssertEqual(SummaryModelFailure.classify(SummaryEngineError.requestFailed(403, "denied")), .auth)
        XCTAssertEqual(SummaryModelFailure.classify(SummaryEngineError.requestFailed(404, "nope")), .endpoint)
        XCTAssertEqual(SummaryModelFailure.classify(SummaryEngineError.requestFailed(500, "boom")), .server)
        XCTAssertEqual(SummaryModelFailure.classify(SummaryEngineError.invalidModelList), .server)
        XCTAssertEqual(SummaryModelFailure.classify(URLError(.timedOut)), .network)
        XCTAssertEqual(SummaryModelFailure.classify(URLError(.cannotConnectToHost)), .network)
    }

    /// 回归护栏：原始错误串**不许**出现在给用户的文案里。
    ///
    /// 原来是 `summaryTestStatus = error.localizedDescription` —— 用户拿到的是一串
    /// 英文技术细节。现在它只进 `Diagnostics.pipeline` 日志。
    func testFailureMessageNeverLeaksRawErrorText() {
        let raw = "NSURLErrorDomain -1004 一长串英文技术细节"
        let state = SummaryModelTestState.failed(
            SummaryModelFailure.classify(NSError(domain: raw, code: 1))
        )
        XCTAssertFalse(
            state.message.contains(raw),
            "原始错误串只该进日志，不该出现在界面上"
        )
        XCTAssertFalse(state.message.contains("NSURLErrorDomain"))
    }
}
