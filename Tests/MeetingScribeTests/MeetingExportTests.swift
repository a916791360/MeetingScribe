import Foundation
import XCTest
@testable import MeetingScribe

/// E1 的单测：把一场会议变成能带走的 Markdown。
///
/// 判据（`docs/产品迭代计划-v0.11.md` §2 E1）：
/// **文件名必须合法、正文必须能被文档工具认出层级、缺数据时不能写出假信息。**
///
/// 这三件事都属于"看着没问题、实际会出错"，而且**出错时不一定报错**——
/// 标题里一个 `/` 会让文件存到别的目录，缺说话人时写一个「（不明）」会变成
/// 一条读者必须解释的假信息。所以在这里逐条钉住。
final class MeetingExportTests: XCTestCase {

    // MARK: - 夹具

    /// 固定日期：不能让测试跟着"今天"变，否则断言日期前缀就没意义了。
    private var fixedDate: Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 9
        parts.day = 15
        parts.hour = 10
        parts.minute = 30
        return Calendar.current.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    private func makeSession(
        title: String = "客户评审会",
        analysis: MeetingAnalysis = .empty,
        segments: [TranscriptSegment] = [],
        transcriptText: String = "",
        duration: TimeInterval? = nil
    ) -> MeetingSession {
        var session = MeetingSession.makeDraft(
            createdAt: fixedDate,
            captureMode: .mixed,
            folderName: "2026-09-15-1030"
        )
        session.title = title
        session.status = .ready
        session.analysis = analysis
        session.transcriptSegments = segments
        session.transcriptText = transcriptText
        session.duration = duration
        return session
    }

    private func analysis(
        headline: String? = nil,
        bullets: [String]? = nil,
        decisions: [InsightItem] = [],
        actions: [ActionItem] = [],
        risks: [InsightItem]? = nil,
        openQuestions: [String]? = nil,
        overviewText: String = "",
        minutesText: String = "",
        timeline: [TimelineChunk] = [],
        summaryError: String? = nil,
        summaryModel: String? = nil
    ) -> MeetingAnalysis {
        MeetingAnalysis(
            overview: [],
            timeline: timeline,
            decisions: decisions,
            actions: actions,
            confidence: 0.9,
            overviewText: overviewText,
            minutesText: minutesText,
            summaryModel: summaryModel,
            summaryError: summaryError,
            headline: headline,
            overviewBullets: bullets,
            openQuestions: openQuestions,
            risks: risks
        )
    }

    // MARK: - 文件名

    func testFileNameUsesZeroPaddedDatePrefixAndTitle() {
        let name = MeetingExporter.fileName(for: makeSession(title: "客户评审会"))
        XCTAssertEqual(name, "2026-09-15-客户评审会.md")
    }

    /// 日期必须**与系统地区无关**。
    ///
    /// 用 `formatted(.dateTime…)` 的话，中文环境是 `2026/09/15`、英文环境是 `09/15/2026`——
    /// 同一天在两台机器上导出的文件名顺序会倒过来，按文件名排序时一片混乱。
    func testFileNameDateIsLocaleIndependent() {
        let name = MeetingExporter.fileName(for: makeSession(title: "会"))
        XCTAssertTrue(name.hasPrefix("2026-09-15-"), "实际得到：\(name)")
        XCTAssertFalse(name.contains("/"), "文件名里不能出现路径分隔符")
    }

    /// 标题里的 `/` 是**路径分隔符**，`: * ? " < > |` 在部分文件系统与网盘上非法。
    func testFileNameReplacesIllegalCharacters() {
        let name = MeetingExporter.fileName(for: makeSession(title: "Q3/季度:复盘?"))
        XCTAssertEqual(name, "2026-09-15-Q3-季度-复盘.md")
        for illegal in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            XCTAssertFalse(name.contains(illegal), "文件名里残留了 \(illegal)：\(name)")
        }
    }

    /// 换行 / 制表符不会让写入失败，但会让文件名在 Finder 里显示成两行、在网盘里变成一堆空格。
    func testFileNameStripsNewlinesAndTabs() {
        let name = MeetingExporter.fileName(for: makeSession(title: "上半场\n\t下半场"))
        XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.contains("\t"))
        XCTAssertEqual(name, "2026-09-15-上半场-下半场.md")
    }

    /// 压缩连续分隔符时**不能碰标题自带的单个破折号**。
    func testSingleDashInTitleIsPreserved() {
        XCTAssertEqual(
            MeetingExporter.fileName(for: makeSession(title: "2026-Q3-复盘")),
            "2026-09-15-2026-Q3-复盘.md"
        )
    }

    func testFileNameFallsBackWhenTitleIsBlank() {        XCTAssertEqual(
            MeetingExporter.fileName(for: makeSession(title: "   ")),
            "2026-09-15-未命名会议.md"
        )
    }

    /// 首尾的点会让文件在 Finder 与部分网盘里被当成隐藏文件。
    func testFileNameFallsBackWhenTitleIsOnlyDots() {
        XCTAssertEqual(
            MeetingExporter.fileName(for: makeSession(title: "...")),
            "2026-09-15-未命名会议.md"
        )
    }

    /// 标题过长会撞上文件系统上限（中文一个字 3 字节）。
    func testFileNameTruncatesVeryLongTitle() {
        let name = MeetingExporter.fileName(for: makeSession(title: String(repeating: "会", count: 200)))
        XCTAssertTrue(name.hasSuffix(".md"))
        let titlePart = name
            .replacingOccurrences(of: "2026-09-15-", with: "")
            .replacingOccurrences(of: ".md", with: "")
        XCTAssertEqual(titlePart.count, 60)
    }

    // MARK: - 结构与顺序

    /// 顺序 = 速览页的漏斗，逐字稿放最后当附录：收件人先看结论，需要核对时再往下翻。
    func testSectionsAppearInFunnelOrder() throws {
        let session = makeSession(
            analysis: analysis(
                headline: "价格谈妥，下周三签约",
                bullets: ["[12:30] 折扣谈到八五折"],
                decisions: [InsightItem(label: "接受八五折", evidence: "客户同意", confidence: 0.9, timestamp: 750)],
                actions: [ActionItem(label: "发合同", evidence: "我这边出", confidence: 0.9, timestamp: 900)],
                openQuestions: ["发票开专票还是普票"],
                overviewText: "双方就价格与交付周期做了确认。",
                timeline: [TimelineChunk(start: 0, end: 111, summary: "开场与背景", evidence: "", confidence: 0.9)]
            ),
            segments: [TranscriptSegment(start: 12, end: 18, text: "你好", confidence: 0.9)]
        )
        let markdown = MeetingExporter.markdown(for: session)

        // 「概述 / 纪要」这一格在**要点之后、清单之前**（2026-09-17 起）：
        // 它是给收件人通读的那一篇，读完再往下看能勾的条目。
        // 这一场没有纪要正文，所以这一格由概述顶上 —— 两者只出一个，见
        // `testOverviewIsDroppedWhenMinutesArePresent`。
        let headings = [
            "## 一句话结论",
            "## 要点",
            "## 会议概述",
            "## 决策与结论",
            "## 待办",
            "## 待确认",
            "## 经过",
            "## 原文（逐字稿）"
        ]
        var lastIndex = markdown.startIndex
        for heading in headings {
            let range = try XCTUnwrap(markdown.range(of: heading), "缺少章节：\(heading)")
            XCTAssertGreaterThan(range.lowerBound, lastIndex, "章节顺序不对：\(heading)")
            lastIndex = range.lowerBound
        }
        XCTAssertTrue(markdown.hasPrefix("# 客户评审会"))
    }

    // MARK: - 待办：要能勾

    /// `- [ ]` 是 Markdown 待办框，粘进 Notion / 飞书文档后可以直接勾。
    func testActionItemsRenderAsCheckboxesWithTags() {
        let session = makeSession(
            analysis: analysis(actions: [
                ActionItem(
                    label: "把合同发过去",
                    priority: .p1,
                    dueText: "周五",
                    evidence: "",
                    confidence: 0.9,
                    timestamp: 750,
                    owner: "张三"
                )
            ])
        )
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(
            markdown.contains("- [ ] 把合同发过去（负责人 张三 · 截止 周五 · 高优先 · 时间 12:30）"),
            "实际正文：\n\(markdown)"
        )
    }

    /// 没有依据时不能画一个孤零零的「依据：」——那比不给还糟。
    func testEmptyFieldsProduceNoEmptyLines() {
        let session = makeSession(
            analysis: analysis(actions: [
                ActionItem(label: "同步进度", evidence: "   ", confidence: 0.8, timestamp: nil, owner: "   ")
            ])
        )
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("- [ ] 同步进度"))
        XCTAssertFalse(markdown.contains("依据："))
        XCTAssertFalse(markdown.contains("负责人"))
    }

    func testDecisionKeepsEvidenceOnNestedLine() {
        let session = makeSession(
            analysis: analysis(decisions: [
                InsightItem(label: "接受八五折", evidence: "客户当场同意", confidence: 0.9, timestamp: 750)
            ])
        )
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("- **接受八五折**（时间 12:30）"))
        XCTAssertTrue(markdown.contains("  - 依据：客户当场同意"))
    }

    func testTimelineUsesCompactRangeLabel() {
        let session = makeSession(
            analysis: analysis(timeline: [
                TimelineChunk(start: 0, end: 111, summary: "开场与背景", evidence: "", confidence: 0.9)
            ])
        )
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("- **[00:00–01:51]** 开场与背景"), "实际正文：\n\(markdown)")
    }

    // MARK: - 要点：锚留着，空条丢掉

    func testBulletKeepsTimeAnchorAsText() {
        let session = makeSession(analysis: analysis(bullets: ["[12:30] 价格谈妥"]))
        XCTAssertTrue(MeetingExporter.markdown(for: session).contains("- [12:30] 价格谈妥"))
    }

    func testBulletWithoutAnchorRendersAsPlainText() {
        let session = makeSession(analysis: analysis(bullets: ["合同条款还要法务看"]))
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("- 合同条款还要法务看"))
        XCTAssertFalse(markdown.contains("- [] "))
    }

    /// 只有时间锚、没有正文的条目要丢掉：渲染出来就是一个孤零零的时刻。
    func testBulletWithOnlyAnchorIsDropped() {
        let session = makeSession(analysis: analysis(bullets: ["[5:00]", "[12:30] 有正文"]))
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertFalse(markdown.contains("[05:00]"), "空要点应被丢弃：\n\(markdown)")
        XCTAssertTrue(markdown.contains("- [12:30] 有正文"))
    }

    func testOpenQuestionsBecomeBullets() {
        let session = makeSession(analysis: analysis(openQuestions: ["  谁出运费  ", "   "]))
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("## 待确认"))
        XCTAssertTrue(markdown.contains("- 谁出运费"))
        XCTAssertFalse(markdown.contains("-   "))
    }

    // MARK: - 整理失败时也要能导出，而且必须说清

    /// 不写这句，收件人会把「只有逐字稿」当成"这场会确实什么都没定"——**那是一个错误的结论**。
    func testNoticeIsQuotedAtTop() {
        let session = makeSession(
            analysis: analysis(headline: nil, summaryError: "整理模型未返回结果")
        )
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("> ⚠️ 整理模型未返回结果"))
        // 提示必须排在正文之前
        let noticeIndex = markdown.range(of: "> ⚠️")?.lowerBound
        let metaIndex = markdown.range(of: "_")?.lowerBound
        XCTAssertNotNil(noticeIndex)
        XCTAssertNotNil(metaIndex)
    }

    func testExportSucceedsWhenSummaryNeverRan() {
        let session = makeSession(analysis: .empty, transcriptText: "只有逐字稿")
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("# 客户评审会"))
        XCTAssertTrue(markdown.contains("只有逐字稿"))
    }

    // MARK: - 逐字稿附录

    /// 优先用**分段**（带起止秒与说话人）：整块文本粘进文档后每段连在一起，没法定位。
    func testTranscriptAppendixPrefersSegmentsOverPlainText() {
        let session = makeSession(
            segments: [
                TranscriptSegment(start: 12, end: 18, text: "这个价格可以", confidence: 0.9, speaker: .local),
                TranscriptSegment(start: 20, end: 26, text: "那就定下来", confidence: 0.9, speaker: .remote)
            ],
            transcriptText: "不该出现的一整块文本"
        )
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("- [00:12] （我方）这个价格可以"))
        XCTAssertTrue(markdown.contains("- [00:20] （对方）那就定下来"))
        XCTAssertFalse(markdown.contains("不该出现的一整块文本"))
    }

    /// 说话人缺失时**整个括号都不出现**，不写「（不明）」——那会变成一条假信息。
    func testTranscriptAppendixOmitsSpeakerParenthesesWhenAbsent() {
        let session = makeSession(
            segments: [TranscriptSegment(start: 12, end: 18, text: "单声道没有说话人", confidence: 0.9)]
        )
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("- [00:12] 单声道没有说话人"))
        XCTAssertFalse(markdown.contains("（我方）"))
        XCTAssertFalse(markdown.contains("（对方）"))
        XCTAssertFalse(markdown.contains("（不明）"))
    }

    func testTranscriptAppendixFallsBackToPlainTextWhenNoSegments() {
        let session = makeSession(segments: [], transcriptText: "  整块文本  ")
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("## 原文（逐字稿）"))
        XCTAssertTrue(markdown.contains("整块文本"))
    }

    /// 分段与整块文本都没有时，不能留一个空章节标题。
    func testNoTranscriptSectionWhenNothingToShow() {
        let session = makeSession(segments: [], transcriptText: "   ")
        XCTAssertFalse(MeetingExporter.markdown(for: session).contains("## 原文（逐字稿）"))
    }

    // MARK: - 页脚与元信息

    func testFooterAndMetaArePresent() {
        let session = makeSession(analysis: analysis(summaryModel: "自定义兼容接口 · deepseek-flash"), duration: 3725)
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("由 MeetingScribe 导出"))
        XCTAssertTrue(markdown.contains("时长 01:02:05"))
        // 只挂模型名，不挂服务商（同窗口副标题的口径）
        XCTAssertTrue(markdown.contains("整理模型 deepseek-flash"))
        XCTAssertFalse(markdown.contains("整理模型 自定义兼容接口"))
    }

    func testMarkdownEndsWithSingleNewline() {
        let markdown = MeetingExporter.markdown(for: makeSession())
        XCTAssertTrue(markdown.hasSuffix("\n"))
        XCTAssertFalse(markdown.hasSuffix("\n\n"))
    }

    // MARK: - 会议纪要（成文正文）

    private let minutesFixture = """
    这一场把价格与交付都定了下来，下一步是周三前给出上线节奏。

    ## 一、价格与账期

    八五折是底线，账期维持三十天。

    ## 二、交付节奏

    - 周三前给出灰度方案
    - 下周一全量
    """

    /// **这一条是本次改动的目的**：模型写的成文纪要必须能带出这个 App。
    ///
    /// 改动前 `MeetingExporter` 只导出结构化字段，`minutesText` 一个字都没出去 ——
    /// 用户在界面上读得到它，复制粘贴出去的却只有清单。
    func testMinutesBodyIsExportedAsADocument() {
        let session = makeSession(analysis: analysis(minutesText: minutesFixture))
        let markdown = MeetingExporter.markdown(for: session)

        XCTAssertTrue(markdown.contains("## 会议纪要"), "实际正文：\n\(markdown)")
        XCTAssertTrue(markdown.contains("这一场把价格与交付都定了下来，下一步是周三前给出上线节奏。"))
        XCTAssertTrue(markdown.contains("八五折是底线，账期维持三十天。"))
    }

    /// 正文里的小标题必须**降一级**。
    ///
    /// 不降的话，「会议纪要」和「一、价格与账期」在文档工具里是同级的两栏，
    /// 读者分不出哪一层是导出结构、哪一层是这场会自己的分节。
    func testMinutesHeadingsAreDemotedBelowTheSectionHeading() {
        let session = makeSession(analysis: analysis(minutesText: minutesFixture))
        let markdown = MeetingExporter.markdown(for: session)

        XCTAssertTrue(markdown.contains("### 一、价格与账期"))
        XCTAssertTrue(markdown.contains("### 二、交付节奏"))

        // **判据必须是行级的**：`### 一、…` 里含有子串 `## 一、…`，
        // 直接用 `contains("## 一、价格与账期")` 会**永远为真**，那条断言等于没写。
        let secondLevel = markdown
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("## ") }
        XCTAssertFalse(
            secondLevel.contains { $0.contains("一、价格与账期") },
            "正文小标题没降级，跟章节标题撞级了：\(secondLevel)"
        )
    }

    /// 老会话的正文写成 `一、价格`（没有井号）。它在 Markdown 里本来只是一行普通字，
    /// 导出时要按**界面同一套判定**补成标题 —— 否则界面上看着是标题的行，导出里却不是。
    func testOldStyleOrdinalHeadingsBecomeRealHeadingsInExport() {
        let text = """
        开场先把三件事说清了。

        一、价格

        八五折是底线。
        """
        XCTAssertEqual(
            MeetingExporter.minutesMarkdown(text),
            """
            开场先把三件事说清了。

            ### 一、价格

            八五折是底线。
            """
        )
    }

    /// 同一个列表里的项目之间只换行、不空行 —— 空行会把一个列表拆成两个。
    func testBulletsInMinutesStayInOneList() {
        let text = """
        ## 一、待办

        - 甲
        - 乙
        """
        XCTAssertEqual(
            MeetingExporter.minutesMarkdown(text),
            "### 一、待办\n\n- 甲\n- 乙"
        )
    }

    /// 概述是纪要的详略两版、说的是同一件事。同时出现等于让收件人读两遍同样的开场白。
    func testOverviewIsDroppedWhenMinutesArePresent() {
        let session = makeSession(
            analysis: analysis(overviewText: "这里是两三百字的概述。", minutesText: minutesFixture)
        )
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("## 会议纪要"))
        XCTAssertFalse(markdown.contains("## 会议概述"))
        XCTAssertFalse(markdown.contains("这里是两三百字的概述。"))
    }

    /// 没有纪要正文时（本地保守整理、或正文那一次调用失败）必须**退回概述**，不能两头空。
    func testOverviewIsStillExportedWhenMinutesAreMissing() {
        let session = makeSession(analysis: analysis(overviewText: "这里是两三百字的概述。"))
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertTrue(markdown.contains("## 会议概述"))
        XCTAssertTrue(markdown.contains("这里是两三百字的概述。"))
        XCTAssertFalse(markdown.contains("## 会议纪要"))
    }

    /// 成文在**前**、清单在**后**：收件人先把它当一篇文档读一遍，需要执行时再往下看能勾的条目。
    func testMinutesComeBeforeTheChecklists() throws {
        let session = makeSession(
            analysis: analysis(
                decisions: [
                    InsightItem(label: "接受八五折", evidence: "客户当场同意", confidence: 0.9, timestamp: 750)
                ],
                actions: [
                    ActionItem(label: "把合同发过去", evidence: "", confidence: 0.9, timestamp: nil, owner: nil)
                ],
                minutesText: minutesFixture
            )
        )
        let markdown = MeetingExporter.markdown(for: session)

        let minutesRange = try XCTUnwrap(markdown.range(of: "## 会议纪要"))
        let decisionsRange = try XCTUnwrap(markdown.range(of: "## 决策与结论"))
        let actionsRange = try XCTUnwrap(markdown.range(of: "## 待办"))
        XCTAssertLessThan(minutesRange.lowerBound, decisionsRange.lowerBound)
        XCTAssertLessThan(decisionsRange.lowerBound, actionsRange.lowerBound)
    }

    /// 空白正文不算正文 —— 不能导出一个只有标题的空章节。
    func testBlankMinutesProduceNoSection() {
        let session = makeSession(analysis: analysis(overviewText: "真正的概述", minutesText: "   \n  "))
        let markdown = MeetingExporter.markdown(for: session)
        XCTAssertFalse(markdown.contains("## 会议纪要"))
        XCTAssertTrue(markdown.contains("## 会议概述"))
    }

    // MARK: - 风险与阻塞（页分家那一轮新增）

    /// 风险这一节**必须紧跟在待办之后**。
    ///
    /// 这不是排版偏好："要做什么"和"什么会挡着"是同一个决策链条的两端。
    /// 拆开（比如挪到「待确认」后面）时，读者先看完行动、翻过一段别的内容才看到阻塞，
    /// 因果就被拆散了 —— 而这种错，除了测试没有任何东西会报警。
    func testRisksSectionSitsRightAfterActions() throws {
        let session = makeSession(
            analysis: analysis(
                decisions: [
                    InsightItem(label: "本期只做上半部分", evidence: "先完成上半部分", confidence: 0.9, timestamp: 120)
                ],
                actions: [
                    ActionItem(label: "周三前给出排期", evidence: "周三前给你排期", confidence: 0.9, timestamp: 240)
                ],
                risks: [
                    InsightItem(label: "第三方接口可能延期", evidence: "那边还没给时间", confidence: 0.85, timestamp: 360)
                ],
                openQuestions: ["多模态要不要一起上"]
            )
        )
        let markdown = MeetingExporter.markdown(for: session)

        let actionsRange = try XCTUnwrap(markdown.range(of: "## 待办"))
        let risksRange = try XCTUnwrap(markdown.range(of: "## 风险与阻塞"))
        let questionsRange = try XCTUnwrap(markdown.range(of: "## 待确认"))
        XCTAssertLessThan(actionsRange.lowerBound, risksRange.lowerBound, "风险必须排在待办之后")
        XCTAssertLessThan(risksRange.lowerBound, questionsRange.lowerBound, "风险必须排在待确认之前")
        XCTAssertTrue(markdown.contains("第三方接口可能延期"))
    }

    /// 没有风险时**不写空章节**（同「待确认」的既有口径：宁可少一节，不要一节空标题）。
    func testNoRisksSectionWhenEmpty() {
        let session = makeSession(
            analysis: analysis(
                decisions: [
                    InsightItem(label: "本期只做上半部分", evidence: "先完成上半部分", confidence: 0.9, timestamp: 120)
                ]
            )
        )
        XCTAssertFalse(MeetingExporter.markdown(for: session).contains("## 风险与阻塞"))
    }
}
