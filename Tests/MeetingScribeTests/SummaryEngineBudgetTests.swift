import Foundation
import XCTest
@testable import MeetingScribe

/// 守住「推理模型把 token 预算烧在思考链上」这个已经踩过一次的坑。
///
/// 现场还原（deepseek-v4.1-flash @ xtapi.site，1.6 万字材料）：
/// `max_tokens: 1800` → `reasoning_tokens: 1800`、`text_tokens: 0`、
/// `finish_reason: "length"`，`content` 一个字符都没有，但 HTTP 是 200。
/// 参数 `enable_thinking: false` / `reasoning_effort: "none"` 该服务商**全部忽略**，
/// 唯一有效的办法就是把预算给足。所以这些下限不是拍脑袋，是实测值。
final class SummaryEngineBudgetTests: XCTestCase {
    func testTokenBudgetsLeaveRoomForReasoningChains() {
        // 实测思考链要吃 2000~3500 token，1800 那种量级一定会失败。
        XCTAssertGreaterThanOrEqual(
            MeetingSummaryEngine.chapterTokenBudget, 6_000,
            "单章摘要在 1.6 万字材料上会被思考链吃光预算，别再往下调"
        )
        XCTAssertGreaterThanOrEqual(
            MeetingSummaryEngine.analysisTokenBudget, 12_000,
            "综合分析要输出完整 JSON，预算是章节的两倍以上才安全"
        )
        XCTAssertGreaterThanOrEqual(
            MeetingSummaryEngine.probeTokenBudget, 1_024,
            "推理模型光思考就要几百 token，连通性测试给 16 会假失败"
        )
        XCTAssertGreaterThan(
            MeetingSummaryEngine.analysisTokenBudget,
            MeetingSummaryEngine.chapterTokenBudget,
            "综合分析输出比单章摘要长，预算必须更高"
        )
    }

    func testBudgetExhaustedErrorExplainsItselfAndSuggestsANextStep() {
        let described = SummaryEngineError.budgetExhausted(8_000).errorDescription ?? ""

        XCTAssertTrue(
            described.contains("8000"),
            "要把实际烧掉的预算写出来，否则用户没法判断严重程度"
        )
        XCTAssertTrue(
            described.contains("思考"),
            "要说清是思考链吃光了预算，而不是含糊地说「没有返回内容」"
        )
        XCTAssertTrue(
            described.contains("非推理模型"),
            "要给出可执行的下一步，而不是让用户自己猜"
        )
    }

    func testEmptyResponseDoesNotExposeProviderPayload() {
        let withPayload = SummaryEngineError.emptyResponse("{\"error\":\"quota\"}")
            .errorDescription ?? ""
        XCTAssertFalse(withPayload.contains("quota"), "服务商控制的内容不能进入可持久化错误文案")

        let withoutPayload = SummaryEngineError.emptyResponse(nil).errorDescription ?? ""
        XCTAssertFalse(
            withoutPayload.contains("回包："),
            "没有回包可带时不要输出一个空的后缀"
        )
    }
}
