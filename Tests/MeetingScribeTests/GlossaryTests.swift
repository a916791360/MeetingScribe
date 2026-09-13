import Foundation
import XCTest

@testable import MeetingScribe

/// 守住「识别术语表」这件事上**唯一一处会静默出错**的地方：方向。
///
/// 用户写的是「正确写法, 误听写法」。替换表必须是「误听 → 正确写法」。
/// 写反了不会崩溃、不会报错，只会把用户本来正确的转写改成错的 —— 而且是
/// 换成那个词自己的同音错字，读起来完全自然。**没人能靠肉眼发现这件事**，
/// 所以必须由测试钉住。
final class GlossaryTests: XCTestCase {

    // MARK: - 解析

    func testParsesFirstTokenAsCanonicalAndRestAsAliases() {
        let glossary = Glossary.parse("客户, 课考, 柯虎")
        XCTAssertEqual(glossary.entries.count, 1)
        XCTAssertEqual(glossary.entries[0].canonical, "客户")
        XCTAssertEqual(glossary.entries[0].aliases, ["课考", "柯虎"])
    }

    func testAcceptsEveryCommaLikeSeparator() {
        // 用户从不同地方粘来的清单，全角/顿号/分号都见过。
        let text = """
        多模态，多摩泰
        工单、公单
        故障系统; 固状系统
        复盘\t复判
        """
        let glossary = Glossary.parse(text)
        XCTAssertEqual(glossary.entries.map(\.canonical), ["多模态", "工单", "故障系统", "复盘"])
        XCTAssertEqual(glossary.entries[0].aliases, ["多摩泰"])
        XCTAssertEqual(glossary.entries[1].aliases, ["公单"])
        XCTAssertEqual(glossary.entries[2].aliases, ["固状系统"])
        XCTAssertEqual(glossary.entries[3].aliases, ["复判"])
    }

    func testStripsListMarkersAndSkipsBlankLines() {
        // 从 markdown / 聊天记录里粘过来时最常见的形态。
        let text = """

        - 多模态, 多摩泰

        * 工单, 公单
        • 复盘
        """
        let glossary = Glossary.parse(text)
        XCTAssertEqual(glossary.entries.map(\.canonical), ["多模态", "工单", "复盘"])
    }

    func testMergesRepeatedCanonicalInsteadOfCreatingTwoEntries() {
        let glossary = Glossary.parse("客户, 课考\n客户, 柯虎")
        XCTAssertEqual(glossary.entries.count, 1, "同一个词写两行应该合并，不是两条")
        XCTAssertEqual(glossary.entries[0].aliases, ["课考", "柯虎"])
    }

    func testAliasConflictIsResolvedByFirstComeFirstServed() {
        // 确定性规则：先写的那个词认领别名。换成"取一个"之类的不定规则，
        // 每次启动解析出来的表可能不同，替换结果就不可复现了。
        let glossary = Glossary.parse("客户, 课考\n客户关系, 课考")
        XCTAssertEqual(glossary.replacementTable["课考"], "客户")
        XCTAssertEqual(glossary.entries[1].aliases, [], "后来的认领不到")
        XCTAssertEqual(glossary.ignoredAliasCount, 1)
    }

    func testDropsAliasEqualToItsOwnCanonical() {
        let glossary = Glossary.parse("客户, 客户")
        XCTAssertEqual(glossary.entries[0].aliases, [])
        XCTAssertEqual(glossary.ignoredAliasCount, 1)
        XCTAssertNil(glossary.replacementTable["客户"], "自己换自己，不该出现在表里")
    }

    func testDropsSingleCharacterAlias() {
        // 单字替换在中文里几乎必然误伤：「固 → 故」会让 `固定` 变成 `故定`。
        let glossary = Glossary.parse("故障系统, 固")
        XCTAssertEqual(glossary.entries[0].aliases, [])
        XCTAssertEqual(glossary.ignoredAliasCount, 1)
    }

    func testCountsDuplicatedAliasAsIgnored() {
        let glossary = Glossary.parse("客户, 课考, 课考")
        XCTAssertEqual(glossary.entries[0].aliases, ["课考"])
        XCTAssertEqual(glossary.ignoredAliasCount, 1)
    }

    func testEmptyTextYieldsEmptyGlossary() {
        XCTAssertEqual(Glossary.parse(""), .empty)
        XCTAssertEqual(Glossary.parse("   \n\n  \t "), .empty)
        XCTAssertEqual(Glossary.parse("\n-\n").entries, [])
    }

    // MARK: - 方向（红线）

    func testReplacementTableOnlyMapsAliasToCanonical() {
        let glossary = Glossary.parse("客户, 课考")
        XCTAssertEqual(glossary.replacementTable, ["课考": "客户"])
        XCTAssertNil(glossary.replacementTable["客户"], "正确写法绝不能当 key —— 那是方向反了")
    }

    func testReplacementTableKeysAreAlwaysAliases() {
        // 这条是上面那条的推广形式：不管用户怎么写，表里的 key 都必须来自别名。
        let glossary = Glossary.parse(Glossary.factoryDefaultText)
        let aliases = Set(glossary.entries.flatMap(\.aliases))
        for key in glossary.replacementTable.keys {
            XCTAssertTrue(aliases.contains(key), "\(key) 不是别名，说明方向或者来源错了")
        }
    }

    // MARK: - 出厂默认（迁移不变式）

    func testFactoryDefaultStillMatchesTheOldHardcodedTable() {
        // 出厂词表把两处硬编码合并成了一份（whisper 的 12 个词 + TranscriptCleaner 的
        // 两条误听）。这条测试钉住「合并没有改变既有行为」——
        // 如果哪天有人顺手改写了出厂文本，这里会立刻红。
        XCTAssertEqual(
            TranscriptCleaner.defaultTerminology,
            ["课考": "客户", "败网": "拜访"]
        )
    }

    func testFactoryDefaultTermsMatchTheHistoricalPrompt() {
        // 1D 实测那一版的词表，逐字一致（顺序也一致）。
        let terms = Glossary.parse(Glossary.factoryDefaultText).promptTerms().terms
        XCTAssertEqual(
            terms,
            ["客户", "拜访", "合同", "预算", "报价", "验收", "渠道", "方案", "排期", "复盘", "交付", "需求"]
        )
    }

    // MARK: - 预算截断

    func testPromptTermsStayWithinBudgetAndCutOnEntryBoundaries() {
        let long = (1...40).map { "术语词条\($0)号" }.joined() // 每个 7 字，远超预算
        let text = (1...40).map { "术语词条\($0)号" }.joined(separator: "\n")
        XCTAssertGreaterThan(long.count, Glossary.whisperTermBudget)

        let budget = Glossary.parse(text).promptTerms()
        XCTAssertLessThanOrEqual(budget.text.count, Glossary.whisperTermBudget)
        XCTAssertTrue(budget.isTruncated)
        XCTAssertEqual(budget.terms.count + budget.droppedCount, 40, "要么进去，要么被算进丢弃数")
        // 每个进去的词都必须是完整的词条，不能出现被切一半的。
        for term in budget.terms {
            XCTAssertTrue(text.contains(term), "\(term) 不在原文里 —— 说明切到了词中间")
        }
    }

    func testPromptTermsNotTruncatedWhenWithinBudget() {
        let budget = Glossary.parse(Glossary.factoryDefaultText).promptTerms()
        XCTAssertFalse(budget.isTruncated)
        XCTAssertEqual(budget.droppedCount, 0)
    }

    // MARK: - 形态 1：whisper 提示词

    func testWhisperInitialPromptContainsSceneSentenceAndTerms() {
        let prompt = Glossary.parse("客户, 课考").whisperInitialPrompt()
        XCTAssertTrue(prompt.hasPrefix(Glossary.sceneSentence))
        XCTAssertTrue(prompt.contains("客户"))
    }

    func testWhisperInitialPromptOmitsTermLineWhenEmpty() {
        // 空词表不能留下一行「常见术语：」 —— 那是句没说完的话。
        let prompt = Glossary.empty.whisperInitialPrompt()
        XCTAssertEqual(prompt, Glossary.sceneSentence)
        XCTAssertFalse(prompt.contains("常见术语"))
    }

    // MARK: - 形态 3：整理约束

    func testSummaryInstructionIsNilWhenEmpty() {
        XCTAssertNil(Glossary.empty.summaryInstruction)
    }

    func testSummaryInstructionCarriesBothHalvesOfTheRule() {
        let instruction = Glossary.parse("客户, 课考").summaryInstruction
        XCTAssertNotNil(instruction)
        XCTAssertTrue(instruction!.contains("客户"))
        // 只说前半句的话，模型会为了让术语表"发挥作用"而把没发生的词塞进结论里。
        XCTAssertTrue(instruction!.contains("不要凭空写进结论"))
    }

    func testSummaryInstructionIsSingleLine() {
        // 它会被插进三处多行 prompt 的中间：多行插值会带上源码缩进。
        let instruction = Glossary.parse("客户, 课考\n工单, 公单").summaryInstruction
        XCTAssertFalse(instruction!.contains("\n"))
    }

    // MARK: - 与 TranscriptCleaner 的衔接

    func testAppliesTerminologyToExistingTranscriptWithoutTouchingStructure() {
        let segments = [
            segment("这次课考反馈说败网时间要改", start: 0),
            segment("客户这边先不动", start: 4)
        ]
        let output = TranscriptCleaner.applyingTerminology(
            segments,
            table: Glossary.parse("客户, 课考\n拜访, 败网").replacementTable
        )
        XCTAssertEqual(output[0].text, "这次客户反馈说拜访时间要改")
        XCTAssertEqual(output[1].text, "客户这边先不动", "本来就是对的，一个字都不该动")
        // 段数与时间戳一律不变 —— 这个函数只换字，用户没让改的地方什么都不动。
        XCTAssertEqual(output.count, segments.count)
        XCTAssertEqual(output.map(\.start), segments.map(\.start))
        XCTAssertEqual(output.map(\.end), segments.map(\.end))
        XCTAssertEqual(output.map(\.confidence), segments.map(\.confidence))
    }

    func testApplyingEmptyTableReturnsInputUntouched() {
        let segments = [segment("这次课考反馈说败网时间要改", start: 0)]
        let output = TranscriptCleaner.applyingTerminology(segments, table: [:])
        XCTAssertEqual(output, segments, "空表就是用户说'什么都别替我改'")
    }

    private func segment(
        _ text: String,
        start: TimeInterval,
        confidence: Double = 0.8
    ) -> TranscriptSegment {
        TranscriptSegment(
            start: start,
            end: start + 3,
            text: text,
            confidence: confidence
        )
    }
}
