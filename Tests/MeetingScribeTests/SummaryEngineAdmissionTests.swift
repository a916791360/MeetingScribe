import XCTest
@testable import MeetingScribe

/// 钉住「决策 / 待办准入判据」。
///
/// 为什么值得单独测：这两条判据原来是两处 `compactMap` 里各抄一遍的 guard，**没有测试**，
/// 于是待办那条里的 `looksUncertain` 把「建议先做 X」这类真待办整条丢掉，长期没人发现
/// （阶段 1 复评发现待办条数只有目标的 1/2）。判据现在抽成静态函数，这里把边界钉死。
final class SummaryEngineAdmissionTests: XCTestCase {

    // MARK: - 待办：宽松判据

    func testActionAdmitsSuggestionAsARealTodo() {
        XCTAssertTrue(
            MeetingSummaryEngine.admitsAction(
                label: "建议先做基础知识库", evidence: "先从知识库开始，后面再谈多模态", confidence: 0.8
            ),
            "「建议先做 X」本身就是一条待办，不能被「建议」两个字杀掉"
        )
        XCTAssertTrue(
            MeetingSummaryEngine.admitsAction(
                label: "考虑把接口先预留出来", evidence: "接口这块要提前预留，后面接多模态", confidence: 0.8
            ),
            "带「考虑」的待办同样要留下"
        )
    }

    func testActionStillRejectsGenuinelyUndecidedItems() {
        for label in ["可能要做多模态", "是否接入海外模型待定", "这块还不确定要不要做"] {
            XCTAssertFalse(
                MeetingSummaryEngine.admitsAction(
                    label: label, evidence: "材料里只是提了一句，没有定下来", confidence: 0.9
                ),
                "「\(label)」只是可能性，不该当成待办派下去"
            )
        }
    }

    // MARK: - 决策：严格判据

    func testDecisionStillRejectsSuggestions() {
        XCTAssertFalse(
            MeetingSummaryEngine.admitsDecision(
                label: "建议做多模态", evidence: "会上只是建议，并没有拍板", confidence: 0.9
            ),
            "建议不等于决定，决策这条要保持严格"
        )
        XCTAssertTrue(
            MeetingSummaryEngine.admitsDecision(
                label: "本期只做接口预留", evidence: "本期只做接口预留，移动端不做", confidence: 0.9
            )
        )
    }

    // MARK: - 两条共同的字数 / 置信度门槛

    func testBothRejectTooShortLabelsAndEvidence() {
        XCTAssertFalse(
            MeetingSummaryEngine.admitsDecision(label: "排期", evidence: "下周排期，负责人小王", confidence: 0.9),
            "label 少于 4 字信息量不够，不该进入决策"
        )
        XCTAssertFalse(
            MeetingSummaryEngine.admitsAction(label: "补文档", evidence: "短", confidence: 0.9),
            "evidence 少于 6 字无法回溯，不该进入待办"
        )
    }

    func testBothRejectLowConfidence() {
        XCTAssertFalse(
            MeetingSummaryEngine.admitsDecision(label: "本期只做接口预留", evidence: "本期只做接口预留", confidence: 0.5),
            "模型自己都只给 0.5，不该当成已定结论"
        )
        XCTAssertFalse(
            MeetingSummaryEngine.admitsAction(label: "本期只做接口预留", evidence: "本期只做接口预留", confidence: 0.5)
        )
    }
}
