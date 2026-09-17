import XCTest

@testable import MeetingScribe

/// 「页分家」那一轮的口径契约：要点去重、导语不重述结论、风险维度的准入与存盘往返。
///
/// 这几条都属于"改完没人比得过"的东西：
///   · 要点与清单重合 73% 是**语义**上的重复，编译器看不见；
///   · 导语抄一遍 headline，只在渲染出来的页面上才刺眼；
///   · 风险条目多了会在待办旁边堆成第二份清单，少了又让"什么会挡着"这个维度整个消失。
/// 所以把口径写成断言，而不是指望下次改 prompt 时记得。
final class SummaryPageSplitTests: XCTestCase {

    private func factsPrompt() -> String {
        MeetingSummaryEngine.factsPrompt(
            source: "[0.0] 八五折是底线，账期三十天",
            directives: "",
            sourceIsChapterSummary: false
        )
    }

    // MARK: - 要点不再重复清单

    /// 要点必须是**清单之外**的信息。
    ///
    /// 原来那句是"覆盖整场的重点（决定、关键数字、风险、下一步）"——
    /// 它明确要求要点**也**写决定，于是同一句结论在两块里各出现一次（实测重合 73%）。
    func testBulletsAreToldNotToRepeatTheChecklists() {
        let prompt = factsPrompt()
        XCTAssertTrue(
            prompt.contains("只写 decisions / actions / risks 没有覆盖的信息"),
            "要点口径没有收窄，重复会原样回来"
        )
        XCTAssertTrue(
            prompt.contains("已经在 decisions、actions 或 risks 里出现过的内容，不要再写一遍"),
            "缺少「不要重复清单」这条硬约束"
        )
    }

    /// 导语不得重述一句话结论 —— 两者在页面上上下相邻，抄一遍最刺眼。
    func testOverviewIsToldNotToRestateTheHeadline() {
        XCTAssertTrue(
            factsPrompt().contains("不要重述 headline 的原句"),
            "导语缺「不得重述 headline」的约束"
        )
    }

    // MARK: - 风险维度

    /// 风险要真的被要求在输出结构里（不然界面上那一块永远是空的）。
    func testRisksAreRequiredInTheOutputSchema() {
        let prompt = factsPrompt()
        XCTAssertTrue(prompt.contains("\"risks\""), "输出结构里没有 risks 字段")
        XCTAssertTrue(prompt.contains("会挡住待办落地的事"), "risks 的语义没有被说清")
    }

    /// 风险的措辞天生带不确定性（"可能延期""如果第三方不配合"）——
    /// **不能**拿决策那套 `looksUncertain` 去筛，否则说得最准的风险会被整条丢掉。
    /// 这条测试守的就是这个判断：同一句话，决策判据丢、风险判据留。
    func testRiskAdmissionKeepsHedgedWordingThatDecisionsWouldDrop() {
        XCTAssertFalse(
            MeetingSummaryEngine.admitsDecision(
                label: "第三方接口可能延期",
                evidence: "那边还没给时间",
                confidence: 0.85
            ),
            "前提变了：决策判据现在不筛『可能』了，这条对照就失效了"
        )
        XCTAssertTrue(
            MeetingSummaryEngine.admitsRisk(
                label: "第三方接口可能延期",
                evidence: "那边还没给时间",
                confidence: 0.85
            ),
            "带不确定措辞的风险被筛掉了 —— 而那正是风险最常见的写法"
        )
    }

    /// 但门槛不能松到没依据也算。**编造的风险比漏掉的风险更糟**：
    /// 它会让人去做无谓的准备。
    func testRiskAdmissionStillRequiresEvidenceAndConfidence() {
        XCTAssertFalse(
            MeetingSummaryEngine.admitsRisk(label: "可能会延期", evidence: "原文", confidence: 0.9),
            "依据太短（<6 字）也放行，等于允许编造"
        )
        XCTAssertFalse(
            MeetingSummaryEngine.admitsRisk(label: "第三方接口可能延期", evidence: "那边还没给时间", confidence: 0.4),
            "低置信度也放行"
        )
        XCTAssertFalse(
            MeetingSummaryEngine.admitsRisk(label: "延期", evidence: "那边还没给时间", confidence: 0.9),
            "label 太笼统（<4 字）也放行"
        )
    }

    // MARK: - 存盘往返

    /// 风险要能存进去、读回来，且**老会话（没有这个键）读出来是 nil 而不是报错**。
    ///
    /// 这是本项目最容易栽的地方：新增字段忘了 Optional + `decodeIfPresent`，
    /// 升级后整条历史记录都读不出来 —— 而且不是"报一个错"，是**所有老会话一起消失**。
    func testRisksRoundTripAndOldSessionsStillDecode() throws {
        let analysis = MeetingAnalysis(
            overview: [],
            timeline: [],
            decisions: [],
            actions: [],
            confidence: 0.9,
            risks: [
                InsightItem(
                    label: "第三方接口可能延期",
                    evidence: "那边还没给时间",
                    confidence: 0.85,
                    timestamp: 360
                )
            ]
        )
        let data = try JSONEncoder().encode(analysis)
        let restored = try JSONDecoder().decode(MeetingAnalysis.self, from: data)
        XCTAssertEqual(restored.risks?.map(\.label), ["第三方接口可能延期"])

        // 老会话：把 risks 键整段拿掉，其余照旧。
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        raw.removeValue(forKey: "risks")
        let legacy = try JSONDecoder().decode(
            MeetingAnalysis.self,
            from: try JSONSerialization.data(withJSONObject: raw)
        )
        XCTAssertNil(legacy.risks, "老会话应当解出 nil，而不是让整条记录读不出来")

        // `nil` 与 `[]` 语义不同：前者是"这场没提"，后者是"提过、这次没筛出"。
        // 空数组必须原样存回来。
        let emptyRisks = MeetingAnalysis(
            overview: [], timeline: [], decisions: [], actions: [], confidence: 0.9, risks: []
        )
        let roundTrip = try JSONDecoder().decode(
            MeetingAnalysis.self,
            from: try JSONEncoder().encode(emptyRisks)
        )
        XCTAssertEqual(roundTrip.risks, [], "空数组被当成 nil 丢掉了")
    }

    /// 只有风险、别的都没有时，也算"这场有产出" —— 否则一份只识别出风险的结果
    /// 会被判成白跑，整场退回本地兜底，用户连那条风险都看不到。
    func testRisksAloneCountAsStructuredFindings() {
        var analysis = MeetingAnalysis.empty
        analysis.risks = [
            InsightItem(label: "第三方接口可能延期", evidence: "那边还没给时间", confidence: 0.85, timestamp: nil)
        ]
        XCTAssertTrue(analysis.hasStructuredFindings)
    }
}
