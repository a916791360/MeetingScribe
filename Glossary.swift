import Foundation

/// 用户维护的「识别术语表」：**一份数据，三种消费形态**。
///
/// 输入是设置页里的多行文本，一行一个词，行内用逗号分隔「会被误听成什么」：
///
/// ```
/// 多模态, 多摩泰
/// 工单, 公单
/// 故障系统
/// ```
///
/// 每行的**第一个词是正确写法**，后面跟的都是要被替换掉的误听写法。三个消费点
/// 共用这一份解析结果，不各自再存一套：
///
/// | 消费点 | 形态 | 谁在用 |
/// |---|---|---|
/// | 转写偏置 | `whisperInitialPrompt()` | `WhisperCLIRunner` 的 `--prompt`（配合 `--carry-initial-prompt`） |
/// | 确定性纠错 | `replacementTable` | `TranscriptCleaner` 的替换表 |
/// | 整理约束 | `summaryInstruction` | 速览 / 纪要两段 prompt，统一专名写法 |
///
/// **方向是这件事唯一的致命点。** 替换表必须是「误听 → 正确写法」，写反了会把用户
/// 本来正确的转写改成错的 —— 而且改得很自然，没人看得出来。所以 `replacementTable`
/// 只从 `aliases` 生成，`canonical` 永远不会出现在 key 上，这一点由单测钉住。
///
/// 解析**不做任何猜测**：分隔符只认逗号类，不认空格（英文词自带空格，用空格切会把
/// `Product Hunt` 切成两半）。宁可解析不出来被用户看见，也不要悄悄切错。
struct Glossary: Equatable, Sendable {

    struct Entry: Equatable, Sendable {
        /// 正确写法。
        let canonical: String
        /// 会被替换掉的误听写法（已剔除等于正确写法的、重复的、以及短到会误伤的）。
        let aliases: [String]
    }

    let entries: [Entry]
    /// 被丢掉了几条别名。UI 拿它解释「我明明写了三条，怎么只生效两条」。
    let ignoredAliasCount: Int

    static let empty = Glossary(entries: [], ignoredAliasCount: 0)

    // MARK: - 解析规则（都是硬约束，改动前先看单测）

    /// 别名短于这个长度的直接丢掉。
    ///
    /// 单字替换在中文里几乎必然误伤：写成「固 → 故」之后，`固定` 会变成 `故定`、
    /// `固然` 会变成 `故然`。用户想修的通常是一个词，不是一个字。
    static let minimumAliasLength = 2

    /// whisper `--prompt` 里词表的预算（按字符算，中文 1 字 ≈ 1 token）。
    ///
    /// 方案 P0-2 记的上限是 `n_text_ctx/2 ≈ 224 token`，中文建议 120 字以内。
    /// 这个预算**只对 whisper 生效** —— 整理模型的上下文是万级，不必跟着限。
    static let whisperTermBudget = 120

    /// 出厂默认词表 = 1D 实测用过的那一版（客户、拜访、合同……）
    /// ＋ `TranscriptCleaner` 原来硬编码的两条误听（课考 / 败网）。
    ///
    /// 把两处硬编码**合并成一份、并且写进设置框的初始值**，是为了让用户看得见它在起什么作用 ——
    /// 「客户、拜访」这类词本来就是从实测误听里总结出来的，藏在一段没人读的注释里可惜了。
    /// 新装用户看到的就是它，1D 的实测收益因此原样保留；用户可以随便改，包括清空。
    static let factoryDefaultText = """
    客户, 课考
    拜访, 败网
    合同
    预算
    报价
    验收
    渠道
    方案
    排期
    复盘
    交付
    需求
    """

    /// 一行里用来分隔「正确写法」和各个别名的字符。**只有逗号类**。
    private static let separators: Set<Character> = [",", "，", "、", ";", "；", "\t"]

    /// 行首常见的列表标记（用户常从别处粘一份带符号的清单过来）。
    private static let listMarkers: Set<Character> = ["-", "*", "•", "·"]

    // MARK: - 入口

    static func parse(_ text: String) -> Glossary {
        var order: [String] = []
        var aliasesByCanonical: [String: [String]] = [:]
        var ownerOfAlias: [String: String] = [:]
        var ignored = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let stripped = strippingListMarker(line)
            guard !stripped.isEmpty else { continue }

            let parts = stripped
                .split(whereSeparator: { separators.contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let canonical = parts.first else { continue }

            if aliasesByCanonical[canonical] == nil {
                aliasesByCanonical[canonical] = []
                order.append(canonical)
            }

            for alias in parts.dropFirst() {
                guard alias != canonical else {
                    // 「客户, 客户」这种 —— 换成自己等于没写，但也**不能**把它放进替换表
                    // （虽然替换成自己无害，留着只会让"生效了几条"这个数虚高）。
                    ignored += 1
                    continue
                }
                guard alias.count >= Self.minimumAliasLength else {
                    ignored += 1
                    continue
                }
                guard aliasesByCanonical[canonical]?.contains(alias) != true else {
                    ignored += 1
                    continue
                }
                // 同一个别名被两个词认领时**先到的赢**。这是确定性规则，不是"取一个"——
                // 否则每次启动解析出的表可能不一样，替换结果就不可复现了。
                guard ownerOfAlias[alias] == nil else {
                    ignored += 1
                    continue
                }
                ownerOfAlias[alias] = canonical
                aliasesByCanonical[canonical, default: []].append(alias)
            }
        }

        let entries = order.map { canonical in
            Entry(canonical: canonical, aliases: aliasesByCanonical[canonical] ?? [])
        }
        return Glossary(entries: entries, ignoredAliasCount: ignored)
    }

    private static func strippingListMarker(_ line: String) -> String {
        guard let first = line.first, listMarkers.contains(first) else { return line }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 形态 1：转写偏置

    /// whisper 的起始提示词。场合句固定，词表来自用户设置。
    ///
    /// 边界没变：**只放术语，不放"这场会在讲什么"**。术语是词表，话题是判断，
    /// 后者猜错会污染整场（这条结论从 1D 之前就成立，实测只是推翻了"术语也有害"那半）。
    static let sceneSentence = "以下是一场中文普通话商务会议的录音转写。"

    func whisperInitialPrompt() -> String {
        let budget = promptTerms()
        guard !budget.text.isEmpty else { return Self.sceneSentence }
        return Self.sceneSentence + "\n常见术语：" + budget.text + "。"
    }

    /// 词表按 `whisperTermBudget` 截断后的结果。截断**只发生在条目边界**，
    /// 不会把一个词切一半（切一半的提示词比少一个词更糟）。
    struct TermBudget: Equatable, Sendable {
        let terms: [String]
        let droppedCount: Int

        var text: String { terms.joined(separator: "、") }
        var isTruncated: Bool { droppedCount > 0 }
    }

    func promptTerms() -> TermBudget {
        var accepted: [String] = []
        var dropped = 0
        var used = 0
        for entry in entries {
            // 「、」也占位置，第一个词不算。
            let cost = entry.canonical.count + (accepted.isEmpty ? 0 : 1)
            guard used + cost <= Self.whisperTermBudget else {
                dropped += 1
                continue
            }
            used += cost
            accepted.append(entry.canonical)
        }
        return TermBudget(terms: accepted, droppedCount: dropped)
    }

    // MARK: - 形态 2：确定性纠错

    /// 「误听 → 正确写法」。**方向由 `aliases` 唯一决定**，见类型注释里的警告。
    var replacementTable: [String: String] {
        var table: [String: String] = [:]
        for entry in entries {
            for alias in entry.aliases {
                table[alias] = entry.canonical
            }
        }
        return table
    }

    // MARK: - 形态 3：整理约束

    /// 给整理模型的一段话。空词表返回 nil —— 不往 prompt 里塞一行空的「必须使用以下写法：」。
    ///
    /// 措辞刻意分成两句：**材料里出现的必须改，材料里没出现的不要凭空写**。
    /// 只说前半句的话，模型会为了让术语表"发挥作用"而把没发生的词塞进结论里。
    ///
    /// **刻意是单行**：它会被插进三处多行 prompt 的中间，多行插值会带上源码缩进，
    /// 单行则完全可控（且这些 prompt 是给人读的，多几行空行只会让人怀疑自己看错了）。
    ///
    /// 这一段的词表**不套 whisper 的 120 字预算**：整理侧上下文是万级字符，
    /// 而 whisper 的 `n_text_ctx/2` 是硬限制。同一个词表，两处预算不同是有意的。
    var summaryInstruction: String? {
        guard !entries.isEmpty else { return nil }
        let terms = entries.map(\.canonical).joined(separator: "、")
        return "本次会议已确认的专有名词写法：\(terms)。"
            + "材料里出现这些名词时必须按这个写法写，不要写成同音异字；"
            + "材料里没出现的，不要凭空写进结论。"
    }
}
