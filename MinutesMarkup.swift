import SwiftUI

/// 纪要正文的**成文排版**：把模型给出的 Markdown 子集解析成块，
/// 再交给 SwiftUI 按一篇文档的样子渲染（小标题 / 自然段 / 项目符号）。
///
/// ## 为什么需要它
///
/// 纪要正文一直由一个 `Text(minutesText)` 直接渲染，而提示词明确写着
/// 「小标题用 `一、二、三` 或 `## 标题` 都可以」（`MeetingSummaryEngine.minutesPrompt`）。
/// 于是模型输出的 `## 一、会员积分的有效期与结算口径` 会**连着井号一起**显示在界面上 ——
/// 一篇本该能直接转发给人看的文档，读起来像没渲染的源码。
/// 真实产出见 `docs/verification/quality/runs/*.json`，每一条都是这个形态。
///
/// ## 为什么自己写解析，而不是引一个 Markdown 库
///
/// 实际需要的只有三类块（小标题 / 自然段 / 项目符号）和一种行内（粗体）。
/// 引库要连带处理链接、代码块、表格、图片 —— 纪要正文里根本不会出现那些，
/// 多出来的解析面只会多出「模型偶发输出某个符号时整页读不了」的机会。
///
/// ## 有意**不**做的一件事：正文里的时间不做成可点锚
///
/// 提示词没有要求模型在正文里标时间。一旦要求，就有「编一个看起来很真的时间」的风险，
/// 而「看着能点、点了跳到无关位置」正是本项目最怕的那类静默损坏。
/// 可核对性由正文下方的决策 / 待办清单承担 —— 它们的时间锚来自结构化字段，
/// 不是模型在散文里自己写的。
enum MinutesMarkup {

    /// 正文里的一个块。
    ///
    /// 段落是**主体**，小标题是**骨架**，项目符号是模型偶尔换用的**列举形态**。
    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
        case bullet(String)
    }

    /// 中文序号小标题的行长上限。
    ///
    /// 这个上限是**护栏**：`一、二两个方面都要考虑` 这类句子在正文里很常见，
    /// 不靠长度把它们挡在外面，一句话就会被从中间切开。
    /// 真实的小标题（`一、MVP版本“故障与问题解决中心”与AI入库`）是 22 个字，30 留了余量。
    static let maximumHeadingLength = 30

    /// 把正文切成块。**纯函数** —— 不碰视图、不读环境，所以能被单测钉住。
    static func blocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        var pendingLines: [String] = []

        func flushParagraph() {
            guard !pendingLines.isEmpty else { return }
            blocks.append(.paragraph(joiningWrappedLines(pendingLines)))
            pendingLines.removeAll()
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                // 空行是**段落边界**，不是待输出的内容。
                flushParagraph()
                continue
            }
            if let heading = headingText(from: line) {
                flushParagraph()
                blocks.append(.heading(heading))
                continue
            }
            if let bullet = bulletText(from: line) {
                flushParagraph()
                blocks.append(.bullet(bullet))
                continue
            }
            pendingLines.append(line)
        }

        flushParagraph()
        return blocks
    }

    // MARK: - 小标题

    /// 这一行是不是小标题；是的话返回标题文字（井号与粗体外壳都已剥掉）。
    ///
    /// 认两种写法，因为**两种都真实存在于存盘数据里**：
    ///
    /// 1. `## 标题`（`###`、`#` 同）—— 提示词明确允许，新产出基本都是这个形态；
    /// 2. `一、标题` —— 老会话里有（`docs/verification/quality/runs/slice1-0-15min.json`
    ///    的正文直接从 `一、MVP版本…` 开始），当时提示词写的是
    ///    「小标题用 `一、二、三` 或 `## 标题` 都可以」。
    ///
    /// 第 2 种收得很紧（要短、不带句子标点），理由见 `maximumHeadingLength`。
    static func headingText(from line: String) -> String? {
        // 模型有时把小标题整个包在粗体里（`**一、标题**`），先剥壳再判定。
        let unwrapped = strippingSurroundingBold(line)

        // 顺序要紧：`### ` 必须先于 `## ` 试，否则会剩下一个 `#` 混进标题文字里。
        for marker in ["### ", "## ", "# "] where unwrapped.hasPrefix(marker) {
            let value = String(unwrapped.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespaces)
            // 只有一个井号、后面什么都没有时不是标题（那种行直接丢掉更糟，退化成段落）。
            return value.isEmpty ? nil : value
        }

        guard unwrapped.count <= maximumHeadingLength else { return nil }
        guard !hasSentencePunctuation(unwrapped) else { return nil }
        guard hasOrdinalPrefix(unwrapped) else { return nil }
        return unwrapped
    }

    /// 行尾是句子标点 —— 那就是叙述，不是标题。
    private static func hasSentencePunctuation(_ line: String) -> Bool {
        guard let last = line.last else { return true }
        return "。，；、！？：".contains(last)
    }

    /// 中文数字（`一`…`十`，含"十一"这类两位数）。
    private static let chineseOrdinalDigits: Set<Character> = [
        "一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
    ]

    /// 行首是不是 `一、` / `十二、` / `1. ` 这类序号。
    ///
    /// **点和顿号要区别对待**：`一、` 后面直接接内容，而 `.` 只有在后面跟空格时才算序号 ——
    /// 不区分的话，正文里的「12.5 万」会被读成序号 `12`，整句被当成小标题拎出来。
    ///
    /// **序号后面不再出现顿号**这一条是专门为「`一、二两个方面都要考虑`」加的：
    /// 那种句子短、又没有句末标点，光靠长度根本挡不住，会把一句正文切成两半。
    /// 代价是「`三、价格、账期与交付`」这类带顿号的标题会**漏判**（退化成普通段落、
    /// 少一次加粗）—— 漏判只损失一点层级，误判会把正文切碎，两者不对等。
    private static func hasOrdinalPrefix(_ line: String) -> Bool {
        guard let separatorIndex = line.firstIndex(where: { "、.．".contains($0) }) else {
            return false
        }
        let separator = line[separatorIndex]
        let prefix = line[line.startIndex..<separatorIndex]

        guard !prefix.isEmpty, prefix.count <= 3 else { return false }
        guard prefix.allSatisfy({ chineseOrdinalDigits.contains($0) || $0.isNumber }) else {
            return false
        }
        // 阿拉伯数字请带一个空格（`1. 第一点`），否则一律当正文。
        if separator != "、" {
            let nextIndex = line.index(after: separatorIndex)
            guard nextIndex < line.endIndex, line[nextIndex] == " " else { return false }
        }
        // `一、` 后面得有内容，`一、` 结尾不算标题。
        let body = line[line.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return false }
        // 序号后面又跟一个中文数字，那是**并列**（`一、二两个方面都要考虑`），不是标题。
        // 这条专门对付"短、又没有句末标点"的句子 —— 长度和标点挡不住它们。
        // 实现上只看紧随其后的第一个字：`一、会员积分…` 是 `会`，`一、二两个方面…` 是 `二`。
        if let first = body.first, chineseOrdinalDigits.contains(first) {
            return false
        }
        // 标题本身通常不再用顿号并列（并列由分节承担），见上。
        return !body.contains("、")
    }

    /// 把整行被 `**` 包住的外壳剥掉（`**一、标题**` → `一、标题`）。
    private static func strippingSurroundingBold(_ line: String) -> String {
        guard line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 else { return line }
        return String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 项目符号

    /// 项目符号行。真实产出里还没有出现过（模型一直用自然段写），
    /// 但提示词没有禁止，所以**解析与渲染都要在** ——
    /// 不支持的话，模型偶尔换一次形态，页面上就会出现一行以 `- ` 开头的字。
    static func bulletText(from line: String) -> String? {
        for marker in ["- ", "* ", "• ", "· "] where line.hasPrefix(marker) {
            let value = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - 折行接回

    /// 把被折成多行的**同一个自然段**接回去。
    ///
    /// 按空行分段是 Markdown 的写法，也是模型实际输出的写法；但长段偶尔被折成两三行，
    /// 逐行输出会在页面上多出一串不该有的行距。
    ///
    /// 接的时候**中文直接贴**（硬折行处补空格，中文读起来就是断的），
    /// **英文单词之间补一个空格**（不补会把两个词粘成一个）。
    /// 两种都在真实材料里出现过，所以这条规则有单测。
    static func joiningWrappedLines(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            if let last = result.last,
               let first = line.first,
               isASCIIWordCharacter(last),
               isASCIIWordCharacter(first) {
                result.append(" ")
            }
            result.append(line)
        }
        return result
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}

/// 纪要正文的**成文渲染**。
///
/// 与速览导语共用同一个容器（`workbenchProsePanel`）—— 这一页里它是"那篇文章"，
/// 而下面的决策 / 待办是条目、靠分隔线立住（判断依据见 `workbenchProsePanel` 的注释：
/// 边界画在**散文与条目之间**）。
struct WorkbenchMinutesProse: View {
    let text: String

    private var blocks: [MinutesMarkup.Block] {
        MinutesMarkup.blocks(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.space4) {
            // 只读渲染、没有状态，所以按位置做身份是安全的（内容变了整块重建即可）。
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .workbenchProsePanel()
    }

    @ViewBuilder
    private func view(for block: MinutesMarkup.Block) -> some View {
        switch block {
        case .heading(let value):
            inline(value, font: AppType.documentSubheading)
                // 小标题上方留白：没有它，标题会跟上一段的最后一行贴在一起，
                // 读起来像段落的一部分（而不是下一节的开头）。
                .padding(.top, AppTheme.space2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let value):
            inline(value, font: AppType.documentBody)
                .lineSpacing(AppType.bodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let value):
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.space2) {
                Text("•")
                    .font(AppType.documentBody)
                    .foregroundStyle(AppTheme.muted)
                inline(value, font: AppType.documentBody)
                    .lineSpacing(AppType.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                // 不要 `Spacer()`：它是弹性的，会跟正文抢宽度
                // （同 `WorkbenchDocumentItemRow` 里那条注释）。
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 行内 Markdown（`**粗体**`）交给系统解析，字号与颜色由调用方给。
    ///
    /// **解析不成功时原样显示**，不吞内容：模型偶发输出半个 `**` 时，
    /// `AttributedString` 会把标记当字面量保留，页面照常能读 ——
    /// 这比"整段消失"或"整页报错"都好。
    private func inline(_ value: String, font: Font) -> Text {
        if let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed).font(font).foregroundColor(AppTheme.ink)
        }
        return Text(value).font(font).foregroundColor(AppTheme.ink)
    }
}
