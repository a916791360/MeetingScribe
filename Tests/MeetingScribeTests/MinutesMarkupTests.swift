import XCTest

@testable import MeetingScribe

/// 纪要正文**成文渲染**的契约。
///
/// ## 为什么要有这一组测试
///
/// 纪要正文在 2026-09-17 之前是一个 `Text(minutesText)` 直接渲染的，而提示词明确允许
/// 模型用 `## 标题` 分段。两边单独看都没问题，合起来的结果就是**界面上显示井号**：
/// 一篇本该能直接转发给人看的文档，读起来像没渲染的源码。
///
/// 这类"看着正常、其实坏了"的问题只有机器判据拦得住 —— 它不会报错、不会崩，
/// 只是每一场会议都差一点点。所以这里的第 1 条测试拿**真实存盘产出**当夹具，
/// 而不是手写一个我自己想得出来的样本。
final class MinutesMarkupTests: XCTestCase {

    // MARK: - 夹具：模型真实产出（随仓库提交的合成语料）

    private func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// 合成语料的产出目录。`synthetic/runs/` 是**入库**的（编造内容，CI 靠它，
    /// 见 `.gitignore` 的注释），和 `quality/runs/`（真实会议、不入库）不同。
    private func syntheticRunURLs() throws -> [URL] {
        let dir = repoRoot().appendingPathComponent("docs/verification/quality/synthetic/runs")
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 从产出 JSON 里取 `analysis.minutesText`。
    private func minutesText(in url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let analysis = root["analysis"] as? [String: Any],
              let value = analysis["minutesText"] as? String
        else { return "" }
        return value
    }

    // MARK: - 第一条：真实产出里的 Markdown 标记绝不外露

    /// 判据：把每一条真实产出的正文解析一遍，**没有任何一块以 `#` 开头**，
    /// 而且确实解出了小标题（否则说明判定写错了、测试自己在空转）。
    func testStoredMinutesNeverExposeMarkdownMarkers() throws {
        let urls = try syntheticRunURLs()
        XCTAssertFalse(urls.isEmpty, "找不到合成产出，这条判据就落空了")

        var sawHeading = false
        var compared = 0

        for url in urls {
            let text = try minutesText(in: url)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            compared += 1

            for block in MinutesMarkup.blocks(from: text) {
                let value: String
                switch block {
                case .heading(let v): value = v; sawHeading = true
                case .paragraph(let v): value = v
                case .bullet(let v): value = v
                }
                XCTAssertFalse(
                    value.hasPrefix("#"),
                    "\(url.lastPathComponent) 里有一块仍带着井号：\(value.prefix(30))"
                )
                XCTAssertFalse(
                    value.contains("## "),
                    "\(url.lastPathComponent) 里有一块残留了 Markdown 标题标记：\(value.prefix(30))"
                )
            }
        }

        XCTAssertGreaterThan(compared, 3, "比对过的产出太少，判据没有说服力")
        XCTAssertTrue(sawHeading, "真实产出里确实有小标题，一条都没解出来就说明判定写错了")
    }

    // MARK: - 小标题判定

    func testHeadingTextStripsEveryMarkerForm() {
        // 提示词允许的写法
        XCTAssertEqual(
            MinutesMarkup.headingText(from: "## 一、会员积分的有效期与结算口径"),
            "一、会员积分的有效期与结算口径"
        )
        // `###` 必须先于 `##` 匹配，否则标题里会混进一个 `#`
        XCTAssertEqual(MinutesMarkup.headingText(from: "### 二级标题"), "二级标题")
        XCTAssertEqual(MinutesMarkup.headingText(from: "# 一级标题"), "一级标题")
        // 模型有时把整行包在粗体里
        XCTAssertEqual(MinutesMarkup.headingText(from: "**一、带粗体壳的标题**"), "一、带粗体壳的标题")
        // 老会话里的写法：没有井号，靠 `一、` 认出来
        // （来源：`docs/verification/quality/runs/slice1-0-15min.json`，那份含真实会议内容、不入库）
        XCTAssertEqual(MinutesMarkup.headingText(from: "一、MVP版本与知识库"), "一、MVP版本与知识库")
        XCTAssertEqual(MinutesMarkup.headingText(from: "十二、收尾"), "十二、收尾")
        XCTAssertEqual(MinutesMarkup.headingText(from: "1. 第一点"), "1. 第一点")
    }

    func testNarrativeLinesAreNotMistakenForHeadings() {
        // 每一条都是**正文**。误判的代价是把一句话切成两半，
        // 而那种错误在页面上看着"只是断了一下"，不会有任何提示。
        XCTAssertNil(MinutesMarkup.headingText(from: "一、二两个方面都要考虑"), "短句 + 顿号并列 → 正文")
        XCTAssertNil(MinutesMarkup.headingText(from: "一、二两个方面都要考虑。"))
        XCTAssertNil(MinutesMarkup.headingText(from: "12.5 万预算还没定"), "小数点后面不跟空格 → 不是序号")
        XCTAssertNil(
            MinutesMarkup.headingText(from: "现有会员积分不过期，导致负债表上挂着一堆历史积分。"),
            "普通叙述句不该被当成标题"
        )
        XCTAssertNil(MinutesMarkup.headingText(from: "## "), "只有一个井号、后面没字 → 不是标题")
        XCTAssertNil(
            MinutesMarkup.headingText(from: "三、价格、账期与交付"),
            "已知取舍：带顿号的标题会漏判（退化成段落），换取不切断正文"
        )
    }

    // MARK: - 分块

    func testBlocksSplitOnBlankLinesAndRecognizeBullets() {
        let text = """
        开场先说了三件事。

        ## 一、价格

        - 八五折是底线
        - 账期三十天
        """
        XCTAssertEqual(MinutesMarkup.blocks(from: text), [
            .paragraph("开场先说了三件事。"),
            .heading("一、价格"),
            .bullet("八五折是底线"),
            .bullet("账期三十天"),
        ])
    }

    func testEmptyOrWhitespaceOnlyTextProducesNoBlocks() {
        // 本地保守整理那条路 `minutesText` 就是空的（`buildMinutesText` 返回 `""`），
        // 这一页在那种情况下只剩决策 / 待办清单。
        XCTAssertEqual(MinutesMarkup.blocks(from: ""), [])
        XCTAssertEqual(MinutesMarkup.blocks(from: "   \n\n  \t \n"), [])
    }

    func testInlineBoldIsLeftForTheRendererInsteadOfBeingSplitOut() {
        // 行内 `**` 不参与分块 —— 它由渲染层交给 `AttributedString`。
        // 解析层若把它当结构处理，正文里成对的粗体就会把一段话切碎。
        XCTAssertEqual(
            MinutesMarkup.blocks(from: "结论是**八五折**可以接受。"),
            [.paragraph("结论是**八五折**可以接受。")]
        )
    }

    // MARK: - 折行接回

    func testWrappedLinesAreJoinedForChineseAndSpacedForEnglish() {
        // 中文硬折行处直接贴：补空格会让中文读起来是断的
        XCTAssertEqual(
            MinutesMarkup.joiningWrappedLines(["这一段的下一行", "接着往下说"]),
            "这一段的下一行接着往下说"
        )
        // 英文单词之间必须补，不补会粘成一个词
        XCTAssertEqual(
            MinutesMarkup.joiningWrappedLines(["the next line", "continues here"]),
            "the next line continues here"
        )
        // 中英混排：判据看**相邻两个字符**是不是 ASCII 字母数字
        XCTAssertEqual(
            MinutesMarkup.joiningWrappedLines(["已上线 1.0", "beta 版本还在测"]),
            "已上线 1.0 beta 版本还在测"
        )
        XCTAssertEqual(
            MinutesMarkup.joiningWrappedLines(["中文结尾，", "中文开头"]),
            "中文结尾，中文开头"
        )
    }

    // MARK: - 提示词必须要求「第一段总述」

    /// 渲染层认得出"第一块是个段落"，但**它管不了模型写不写**。这条测试钉的是
    /// 提示词里确实写着这条要求 —— 2026-09-17 之前没写，真实产出就全部从
    /// `## 一、…` 直接开始（`syn-good.json` 就是这样）。
    func testMinutesPromptAsksForALeadParagraphBeforeAnyHeading() {
        let prompt = MeetingSummaryEngine.minutesPrompt(
            source: "材料",
            directives: "",
            sourceIsChapterSummary: false
        )
        XCTAssertTrue(prompt.contains("总述"), "提示词没有要求总述段")
        XCTAssertTrue(prompt.contains("`## 一、标题`"), "小标题格式没有收成一种")
        // 旧文案写着「`一、二、三` 或 `## 标题` 都可以」，留着它同一条会话里
        // 两种写法会混着出现，界面与导出的层级判定都得跟着兜两套。
        XCTAssertFalse(prompt.contains("或 `## 标题` 都可以"), "两种小标题写法还留着")
    }

    /// 与上一条配对：提示词要求的那段总述，在解析层必须落在 `.paragraph` 上。
    /// 落到 `.heading` 就意味着"总述被渲染成小标题"，开头又与内容撞在一起。
    func testTheLeadParagraphStaysAParagraph() {
        let text = """
        这一场把价格与交付都定了下来，下一步是周三前给出上线节奏。

        ## 一、价格
        """
        let blocks = MinutesMarkup.blocks(from: text)
        XCTAssertEqual(
            blocks.first,
            .paragraph("这一场把价格与交付都定了下来，下一步是周三前给出上线节奏。")
        )
        XCTAssertEqual(blocks.count, 2)
    }
}
