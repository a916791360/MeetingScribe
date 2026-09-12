import XCTest
@testable import MeetingScribe

/// 守住窗口副标题里「模型名」的裁剪口径。
///
/// 背景：`summaryModel` 存下来的是 `SummaryModelSettings.displayName`，
/// 格式为 `<服务商> · <模型名>`。设置面板要用完整名字（要交代这套凭据连的是谁），
/// 但窗口副标题只有一行，服务商名在那里是噪音 —— 用户明确要求别再显示
/// 「自定义兼容接口」这一截。
///
/// 所以裁的是**展示层**（`modelLabel`），不是存储层：`summaryModel` 原样保留，
/// 否则设置面板和历史数据都会跟着变形。
final class MeetingAnalysisModelLabelTests: XCTestCase {

    private func analysis(summaryModel: String?) -> MeetingAnalysis {
        MeetingAnalysis(
            overview: [],
            timeline: [],
            decisions: [],
            actions: [],
            confidence: 0,
            overviewText: "",
            minutesText: "",
            summaryModel: summaryModel,
            summaryError: nil
        )
    }

    /// 主用例：把「服务商 · 模型」裁成只剩模型。
    func testStripsProviderPrefix() {
        XCTAssertEqual(
            analysis(summaryModel: "自定义兼容接口 · deepseek-v4.1-flash").modelLabel,
            "deepseek-v4.1-flash"
        )
        XCTAssertEqual(
            analysis(summaryModel: "DeepSeek · deepseek-chat").modelLabel,
            "deepseek-chat"
        )
    }

    /// 没有分隔符时原样返回。本地规则档存的就是纯标题（「本地保守整理」），
    /// 不能因为找不到分隔符就被裁成空。
    func testKeepsNameWithoutSeparator() {
        XCTAssertEqual(analysis(summaryModel: "本地保守整理").modelLabel, "本地保守整理")
    }

    /// 空 / 全空白 / nil 一律当作「没有模型信息」，返回 nil 而不是空串 ——
    /// 否则 `metaLine` 会多拼出一个空片段，副标题末尾挂一串孤零零的分隔符。
    func testBlankValuesBecomeNil() {
        XCTAssertNil(analysis(summaryModel: nil).modelLabel)
        XCTAssertNil(analysis(summaryModel: "").modelLabel)
        XCTAssertNil(analysis(summaryModel: "   ").modelLabel)
    }

    /// 分隔符后面是空白时退回原名，避免裁出空串。
    ///
    /// 注意：退回的是**trim 过**的原名 —— 尾随空白先被去掉，于是
    /// 「自定义兼容接口 · 」在裁切前就变成了「自定义兼容接口 ·」，
    /// 里面已经没有「 · 」这个带空格的完整分隔符，所以整串原样返回。
    func testFallsBackWhenModelPartIsEmpty() {
        XCTAssertEqual(analysis(summaryModel: "自定义兼容接口 · ").modelLabel, "自定义兼容接口 ·")
        XCTAssertEqual(analysis(summaryModel: "自定义兼容接口 ·   ").modelLabel, "自定义兼容接口 ·")
        XCTAssertNotEqual(analysis(summaryModel: "自定义兼容接口 · ").modelLabel, "")
    }

    /// 前后空白不该跟着进副标题。
    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(
            analysis(summaryModel: "  自定义兼容接口 · deepseek-v4.1-flash  ").modelLabel,
            "deepseek-v4.1-flash"
        )
    }

    /// 端到端确认：副标题里不再出现服务商名，但仍带模型名。
    func testMetaLineDropsProviderButKeepsModel() {
        var session = MeetingSession.makeDraft(
            createdAt: Date(timeIntervalSince1970: 1_756_000_000),
            captureMode: .microphone,
            folderName: "fixture"
        )
        session.status = .ready
        session.analysis = analysis(summaryModel: "自定义兼容接口 · deepseek-v4.1-flash")
        let line = session.metaLine
        XCTAssertFalse(line.contains("自定义兼容接口"), "副标题不该再出现服务商名：\(line)")
        XCTAssertTrue(line.contains("deepseek-v4.1-flash"), "副标题应保留模型名：\(line)")
    }
}
