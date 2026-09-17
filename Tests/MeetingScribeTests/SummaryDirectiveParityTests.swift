import XCTest

@testable import MeetingScribe

/// 「不管这场会是录的还是导入的、不管有多长，速览与纪要都必须是一套口径」的契约。
///
/// ## 为什么要有这一组测试
///
/// 2026-09-17 查出一处**读起来完全正常**的不一致：说话人约定（"写清归属"）只被拼进了
/// **分章**那一步的 prompt，而分章是中间产物 —— 真正产出速览与纪要的是它后面那一步，
/// 那一步从头到尾没收到过这条指令。当时的依据是"分章是唯一看得见原文的一步"，
/// 这句话对长会成立，对 ≤2.4 万字的直接路径（大多数会议）**不成立**：
/// 那一步拿到的就是带 `[我方]/[对方]` 的原文。
///
/// 这类问题的共性是：**三处 prompt 各自拼「同一件事」，谁也没法证明它们说的是同一句话。**
/// 所以修法不是"记得改三处"，而是把指令块收成一处构造器，再用这里的测试钉住：
///
/// 1. 分章那一步拿到的字**与拆分前逐字相同**（它已经跑在生产上，不许顺手改字）；
/// 2. 速览段与纪要段拿到的是**同一份**指令块，各出现一次；
/// 3. 没有说话人的材料（导入 / 单路录音 / 老会话）拿到的东西**与改动前一模一样**。
final class SummaryDirectiveParityTests: XCTestCase {

    private let material = "[0.0] [我方] 八五折是我们的底线\n[6.0] [对方] 账期三十天没问题"

    // MARK: - 说话人约定的拆分本身

    func testLegendIsExactlyTheTwoPartsJoined() {
        // 分章那一步用的是 `materialLegend`。它现在由两块拼成，
        // 而不是第三份文案 —— 这条等式断了，就说明有人把其中一块改成了别的话。
        XCTAssertEqual(
            TranscriptSpeaker.materialLegend,
            TranscriptSpeaker.materialMarkerExplanation + "\n"
                + TranscriptSpeaker.speakerAttributionDirective
        )
    }

    func testTheTwoPartsAreTwoDifferentThings() {
        // 拆开的意义就在于它们**适用条件不同**：一块是"标记是什么意思"，
        // 一块是"要求你写归属"。如果有人把它们写成同一句话，提示词里就会出现两遍，
        // 模型会以为那是最重要的要求。
        XCTAssertTrue(TranscriptSpeaker.materialMarkerExplanation.contains("[我方]"))
        XCTAssertTrue(TranscriptSpeaker.materialMarkerExplanation.contains("[对方]"))

        // 归属那一块**不解释标记**（它不带方括号）。注意它正文里确实会出现"我方/对方"
        // 这两个词 —— 那是让模型照抄进「谁来做」，不是解释标记。
        XCTAssertFalse(TranscriptSpeaker.speakerAttributionDirective.contains("[我方]"))
        XCTAssertFalse(TranscriptSpeaker.speakerAttributionDirective.contains("[对方]"))
        XCTAssertTrue(TranscriptSpeaker.speakerAttributionDirective.contains("归属"))
    }

    // MARK: - 指令块构造器

    func testDirectivesDropsBlankBlocksInsteadOfLeavingGaps() {
        XCTAssertEqual(
            MeetingSummaryEngine.directives(terminology: "", markerExplanation: "  ", attribution: nil),
            ""
        )
        XCTAssertEqual(
            MeetingSummaryEngine.directives(terminology: "A", markerExplanation: nil, attribution: "B"),
            "A\nB"
        )
        XCTAssertEqual(
            MeetingSummaryEngine.directives(terminology: nil, markerExplanation: "\n M \n", attribution: nil),
            "M"
        )
    }

    func testTerminologyComesFirstAndLegendLast() {
        let glossary = Glossary(
            entries: [Glossary.Entry(canonical: "易运盈", aliases: ["易韵盈"])],
            ignoredAliasCount: 0
        )
        let value = MeetingSummaryEngine.chapterDirectives(glossary: glossary, hasSpeakers: true)

        XCTAssertTrue(value.hasPrefix(glossary.summaryInstruction ?? "\u{0}"), value)
        XCTAssertTrue(value.hasSuffix(TranscriptSpeaker.materialLegend), value)
    }

    // MARK: - 分章那一步：与拆分前逐字相同（不许顺手改字）

    func testChapterStageGetsTheWholeLegendOnlyWhenSpeakersExist() {
        XCTAssertEqual(
            MeetingSummaryEngine.chapterDirectives(glossary: .empty, hasSpeakers: true),
            TranscriptSpeaker.materialLegend,
            "分章那一步拿到的必须还是拆分前那一整块"
        )
        XCTAssertEqual(
            MeetingSummaryEngine.chapterDirectives(glossary: .empty, hasSpeakers: false),
            "",
            "没有说话人的材料，分章那一步一个字都不该多说"
        )
    }

    // MARK: - 产出速览 / 纪要那一步：本次修的就是这里

    func testAttributionReachesTheStageThatProducesVisibleOutput() {
        // **这条是整个改动的目的**：归属要求必须到达产出速览与纪要的那一步，
        // 而且与"材料是原文还是章节摘要"无关。
        for sourceIsChapterSummary in [false, true] {
            let value = MeetingSummaryEngine.analysisDirectives(
                glossary: .empty,
                sourceIsChapterSummary: sourceIsChapterSummary,
                hasSpeakers: true
            )
            XCTAssertTrue(
                value.contains(TranscriptSpeaker.speakerAttributionDirective),
                "sourceIsChapterSummary=\(sourceIsChapterSummary) 时归属要求丢了"
            )
        }
    }

    func testMarkersAreExplainedOnlyWhereMarkersActuallyAppear() {
        let fromRawTranscript = MeetingSummaryEngine.analysisDirectives(
            glossary: .empty, sourceIsChapterSummary: false, hasSpeakers: true
        )
        let fromChapterSummaries = MeetingSummaryEngine.analysisDirectives(
            glossary: .empty, sourceIsChapterSummary: true, hasSpeakers: true
        )

        XCTAssertTrue(
            fromRawTranscript.contains(TranscriptSpeaker.materialMarkerExplanation),
            "直接路径拿到的是带 [我方]/[对方] 的原文，必须解释记号"
        )
        XCTAssertFalse(
            fromChapterSummaries.contains(TranscriptSpeaker.materialMarkerExplanation),
            "综合路径拿到的是章节摘要、里面没有记号，解释记号就是往 prompt 里塞假信息"
        )
    }

    func testAnalysisDirectivesAreEmptyWithoutSpeakersAndGlossary() {
        // **导入的会议走的就是这一条**：它必须拿到空串，也就是与改动前逐字相同。
        XCTAssertEqual(
            MeetingSummaryEngine.analysisDirectives(
                glossary: .empty, sourceIsChapterSummary: false, hasSpeakers: false
            ),
            ""
        )
    }

    // MARK: - 两段 prompt 必须是同一套口径

    private func prompts(
        directives: String,
        sourceIsChapterSummary: Bool,
        source: String? = nil
    ) -> [(String, String)] {
        let text = source ?? material
        return [
            (
                "速览",
                MeetingSummaryEngine.factsPrompt(
                    source: text,
                    directives: directives,
                    sourceIsChapterSummary: sourceIsChapterSummary
                )
            ),
            (
                "纪要",
                MeetingSummaryEngine.minutesPrompt(
                    source: text,
                    directives: directives,
                    sourceIsChapterSummary: sourceIsChapterSummary
                )
            ),
        ]
    }

    func testBothStagesCarryTheSameDirectiveBlockExactlyOnce() {
        let directives = MeetingSummaryEngine.analysisDirectives(
            glossary: .empty, sourceIsChapterSummary: false, hasSpeakers: true
        )

        for (name, prompt) in prompts(directives: directives, sourceIsChapterSummary: false) {
            XCTAssertEqual(
                prompt.components(separatedBy: TranscriptSpeaker.speakerAttributionDirective).count - 1,
                1,
                "\(name) prompt 里归属要求应恰好出现一次"
            )
            XCTAssertEqual(
                prompt.components(separatedBy: TranscriptSpeaker.materialMarkerExplanation).count - 1,
                1,
                "\(name) prompt 里标记解释应恰好出现一次"
            )
        }
    }

    func testBothStagesSayNothingAboutSpeakersWhenTheMeetingHasNone() {
        // 导入 / 单路录音 / 升级前的老会话走这条路：**两段 prompt 里一个跟说话人有关的字
        // 都不该出现**。这是"本次改动对导入路径零影响"的机器判据 —— 不是靠人工比对。
        //
        // 这里必须喂一份**本身就没有说话人**的材料：带 `[我方]` 的材料会被原样拼到 prompt
        // 末尾，于是"prompt 里有没有我方"这个判据量到的是材料、不是指令块。
        // （第一版就是这么错的 —— 四条断言全红，而代码其实是对的。）
        let noSpeakerMaterial = "[0.0] 八五折是我们的底线\n[6.0] 账期三十天没问题"
        for (name, prompt) in prompts(
            directives: "",
            sourceIsChapterSummary: false,
            source: noSpeakerMaterial
        ) {
            XCTAssertFalse(prompt.contains("我方"), "\(name) prompt 不该提到我方")
            XCTAssertFalse(prompt.contains("对方"), "\(name) prompt 不该提到对方")
            XCTAssertFalse(prompt.contains("归属"), "\(name) prompt 不该要求归属")
            XCTAssertFalse(prompt.contains("说话人"), "\(name) prompt 不该提到说话人")
        }
    }

    func testBothStagesReceiveTheSourceMaterialVerbatim() {
        // 指令块是加进去的，材料本身必须原样落在末尾 —— 拼接方式改了会把材料挤掉，
        // 而那种错误表现为"模型说材料里没有"，很难查。
        for (name, prompt) in prompts(directives: "术语约束", sourceIsChapterSummary: false) {
            XCTAssertTrue(prompt.hasSuffix(material), "\(name) prompt 结尾不是原样材料")
            XCTAssertEqual(prompt.components(separatedBy: "术语约束").count - 1, 1)
        }
    }

    func testPromptsHaveNoUnresolvedPlaceholders() {
        // prompt 从"就地写在函数里"改成"纯函数构造"之后，多了一层参数传递；
        // 传漏一个参数就会在提示词里留下一段没展开的 `\(...)` 字面量，
        // 而模型会把它当成材料的一部分照读。
        for (name, prompt) in prompts(directives: "术语", sourceIsChapterSummary: true) {
            XCTAssertFalse(prompt.contains("\\("), "\(name) prompt 里留下了未展开的插值")
        }
    }

    func testPromptsStartAtColumnZeroAfterBeingMovedIntoFunctions() {
        // 多行字符串的**缩进是按结束定界符算的**：把 `"""` 从
        // `let prompt = """` 挪到函数体里的时候，只要结束定界符退了一档，
        // 提示词每一行都会**多出一段前导空格**。那种错误不会让任何断言变红
        // （`contains` 照样命中），字面上却把整份 prompt 改了。
        for (name, prompt) in prompts(directives: "", sourceIsChapterSummary: false) {
            XCTAssertTrue(prompt.hasPrefix("你正在整理一场中文工作会议"), "\(name) prompt 首行多了缩进")
            XCTAssertFalse(prompt.contains("\n        你正在"), "\(name) prompt 里出现了带缩进的行")
        }
    }

    func testChapterSummariesAndRawTranscriptGetDifferentSourceHints() {
        // 两段 prompt 都按"材料是什么"改一句话。这条提示**必须跟着材料走**：
        // 把章节摘要当成逐字稿去"覆盖整场"，模型会试图凭空补出中间的时间线。
        let raw = prompts(directives: "", sourceIsChapterSummary: false)
        let synthesized = prompts(directives: "", sourceIsChapterSummary: true)

        for (name, prompt) in raw {
            XCTAssertTrue(prompt.contains("带时间戳的会议逐字稿"), "\(name)（原文）缺少逐字稿提示")
        }
        for (name, prompt) in synthesized {
            XCTAssertTrue(prompt.contains("章节摘要"), "\(name)（章节摘要）缺少摘要提示")
        }
    }

    // MARK: - 「有没有说话人」这个判据只有一处

    func testHasSpeakerLabelsIsTrueIfAnySegmentCarriesOne() {
        let plain = TranscriptSegment(start: 0, end: 1, text: "一句", confidence: 0.9)
        var tagged = TranscriptSegment(start: 6, end: 9, text: "另一句", confidence: 0.9)
        tagged.speaker = .remote

        XCTAssertFalse([TranscriptSegment]().hasSpeakerLabels)
        XCTAssertFalse([plain].hasSpeakerLabels)
        // **一段带标签就算有**：双声道合并后本来就允许有段落没分出来（重叠、空隙），
        // 那些行没有前缀是事实，但不能因此把整场的归属要求撤掉。
        XCTAssertTrue([plain, tagged].hasSpeakerLabels)
    }
}
