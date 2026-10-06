import XCTest
@testable import MeetingScribe

final class LocalActionDeadlineTests: XCTestCase {
    private func analysis(_ segment: TranscriptSegment) -> MeetingAnalysis {
        let background = (1...4).map { index in
            TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 10), text: "合成背景第\(index)部分记录测试环境、产品文档和接口资料。讨论材料足够详细，不涉及人员分配或截止日期，也不包含真实业务数据和任何云端凭据。", confidence: 0.95)
        }
        return MeetingAnalysisBuilder.build(from: [segment] + background)
    }

    func testSpecificWeekdayAndTimeAreNotShortenedToWeek() throws {
        for deadline in ["下周三", "本周五下午", "周五下午三点", "星期一上午十点半", "下周", "月底"] {
            let segment = TranscriptSegment(start: 0, end: 10, text: "我负责完成接口验收，约定在\(deadline)提交结果并确认。", confidence: 0.95)
            let action = try XCTUnwrap(analysis(segment).actions.first)
            XCTAssertEqual(action.dueText, deadline)
        }
    }

    func testCalendarDateAndRelativeDayKeepTimeQualifier() throws {
        for deadline in ["2026年10月9日下午三点", "10月9日", "明天上午", "后天中午"] {
            let segment = TranscriptSegment(start: 0, end: 10, text: "我负责完成接口验收，约定在\(deadline)提交结果并确认。", confidence: 0.95)
            let action = try XCTUnwrap(analysis(segment).actions.first)
            XCTAssertEqual(action.dueText, deadline)
        }
    }

    func testMissingDeadlineIsNotInvented() throws {
        let segment = TranscriptSegment(start: 0, end: 10, text: "我负责完成接口验收，暂时还没有约定提交时间。", confidence: 0.95)
        let action = try XCTUnwrap(analysis(segment).actions.first)
        XCTAssertNil(action.dueText)
    }
}
