import Foundation

/// 逐字稿后处理：把 whisper 的原始分段整成「人读得下去、模型也啃得动」的样子。
///
/// **为什么必须有这一步**（阶段 0 基线实测，2026-09-13；见
/// `docs/质量提升执行计划.md` §1.5）：
///
/// - 871 段里有 91 段（10.4%）是复读，最长的一串同一个句子重复了 86 次；
/// - 段均只有 15 字，模型的句子边界只能靠猜；
/// - 真正该丢的「垃圾段」只有 0.6% —— 所以**丢内容不是重点，复读和碎段才是**。
///
/// 内部优先级照这个实测调整过（不是按直觉排的）：
/// **复读折叠 ≫ 术语替换 > 按句合并 > 丢低置信**。
///
/// 全部是纯函数、确定性：同一份输入永远得到同一份输出，不碰网络、不改模型调用。
/// 也刻意做成**近似幂等**的 —— 清洗过的逐字稿再洗一遍不会继续缩水，
/// 因为清洗结果会被存回会话（`session.transcriptSegments`），而评测集是从会话导出的。
enum TranscriptCleaner {

    struct Options: Sendable {
        /// 术语替换表（误听 → 正确写法）。默认值来自 `Glossary` 的出厂词表，
        /// **设置页里用户自己写的词由 `MeetingStore` 显式传进来**（P1-3 / 2D）。
        var terminology: [String: String] = TranscriptCleaner.defaultTerminology
        /// 连续重复达到几次才算「复读」。3 是保守值：中文里「看看」「慢慢」「非常非常」
        /// 这类正常的双叠词不该被动。
        var repeatThreshold: Int = 3
        /// 段内重复还要**重复够长**才折叠（重复次数 × 单元长度 ≥ 这个值）。
        ///
        /// 3 个字以内的重复一律放过：会上连说三个「对」是真在表态，
        /// 而 `对对对` 和 ASR 卡住的 `对对对` 从文本上根本分不开。
        /// 设成 6 之后，`对对对`（3 字）保留、`对对对对对对`（6 字）折叠 —— 明显卡带才处理。
        var minimumLoopSpan: Int = 6
        /// 相邻段复读时，文本短于这个长度就不折叠 —— 开会时「对」「好」这种短应答
        /// 是真的在说话，不是幻觉循环，折叠掉就丢信息了。
        var minimumRepeatLength: Int = 6
        /// 合并后的目标上限（字符）。超过就断开新起一段。
        var mergeLimit: Int = 160
        /// 低于这个置信度、**且**短到不可能有信息的段，直接丢掉。
        var dropConfidence: Double = 0.2
        /// 配合 `dropConfidence` 的长度门槛。
        var dropMaxLength: Int = 6

        static let `default` = Options()
    }

    /// 出厂术语表。**这里不再写死词条** —— 它和 whisper 的 `--prompt` 词表是同一份数据，
    /// 都由 `Glossary.factoryDefaultText` 派生。分成两处写会漂移：改了设置页的默认词表，
    /// 后处理这一处却还是旧的，而"改了却只生效一半"是最难发现的一类 bug。
    ///
    /// 留空的词条一律不替换 —— 宁可少纠，不要纠错。
    static let defaultTerminology: [String: String] =
        Glossary.parse(Glossary.factoryDefaultText).replacementTable

    // MARK: - 入口

    static func clean(_ segments: [TranscriptSegment], options: Options = .default) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }
        let sorted = segments.sorted { $0.start < $1.start }
        let collapsed = collapseRepeats(sorted, options: options)
        let corrected = collapsed.map { applyTerminology($0, options.terminology) }
        let merged = mergeBySentence(corrected, limit: options.mergeLimit)
        // **并句之后要再折叠一次**：并句会把「上一段的尾 + 这一段的头」拼起来，
        // 于是原本不相同的相邻段可能变得一模一样（实测就是这么冒出一串重复的）。
        // 只折一遍的话，这批重复要等到"第二次清洗"才被发现 —— 那就不幂等了，
        // 而清洗结果是要写回会话的，评测集也从会话导出，不幂等会越洗越少。
        let collapsedAgain = collapseRepeats(merged, options: options)
        return dropLowConfidence(collapsedAgain, options: options)
    }

    /// 只做术语替换，**不动段结构**。
    ///
    /// 存在的理由：替换表是用户随时会改的设置（"哦，这个公司名一直听错了"），而
    /// 上面那条完整清洗只在**转写那一刻**跑一次 —— 对已经存盘的逐字稿，后面再加的词
    /// 一个都不会生效。这与 2C 踩过的坑是同一类错误：**前置处理只对新产出生效，
    /// 已存盘的数据不会自己变好**（见 `.learnings` LRN-013）。
    ///
    /// 所以「重新整理纪要」时会先过一遍这个函数，让用户刚加的纠错词立刻在这条已有记录上生效。
    /// 它刻意**只做替换**：不折叠复读、不并句、不丢段 —— 段数与时间戳一律不变，
    /// 只有字符按用户明示的方向变。用户没让改的地方，一个字都不动。
    ///
    /// **人工改过的段（`manuallyEditedAt != nil`）原样穿过**，见函数内注释。
    static func applyingTerminology(
        _ segments: [TranscriptSegment],
        table: [String: String],
        skippingManuallyEdited: Bool = true
    ) -> [TranscriptSegment] {
        guard !table.isEmpty, !segments.isEmpty else { return segments }
        // 人工改过的段要**原样穿过**：用户会去改一句，是因为**他那句听清了**。
        // 那句就是他确认过的真相，而术语表是「猜出来的纠错」—— 用猜的覆盖确认过的，
        // 覆盖之后文本依然通顺、依然存得下、依然渲染得出来，**没有任何报错**。
        // 用户只会觉得"我明明改过了，怎么又变回去"。
        return segments
            .sorted { $0.start < $1.start }
            .map { segment in
                if skippingManuallyEdited, segment.manuallyEditedAt != nil { return segment }
                return applyTerminology(segment, table)
            }
    }

    /// 只做复读折叠，不做合并 / 替换 / 丢弃。
    ///
    /// 给评测脚本量「复读这一项本身该丢掉多少字」用：清洗后的总字数一定会比原文少
    /// （复读占 10.4%，按设计就该丢），所以判断"有没有删过头"必须拿这个数当分母，
    /// 而不是拿原始总字数当分母。
    static func removingRepeats(
        _ segments: [TranscriptSegment],
        options: Options = .default
    ) -> [TranscriptSegment] {
        collapseRepeats(segments.sorted { $0.start < $1.start }, options: options)
    }

    // MARK: - 1 复读折叠（优先级最高：占 10.4% 的段）

    /// 折叠两种复读：
    /// 1. **段内**：`这个这个这个方案` → `这个方案`；
    /// 2. **段间**：相邻段说的是同一句话（whisper 在长静音或噪声上会进入自重复循环，
    ///    实测有一串重复了 86 次）。段间复读把时间区间并起来，保留更长的那份文本。
    private static func collapseRepeats(
        _ segments: [TranscriptSegment],
        options: Options
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for var segment in segments {
            segment.text = collapseInnerRepeats(
                segment.text,
                threshold: options.repeatThreshold,
                minimumSpan: options.minimumLoopSpan
            )
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if var last = result.last,
               last.speaker == segment.speaker,
               segment.start <= last.end + 1,
               isRepeat(last.text, trimmed, minimumLength: options.minimumRepeatLength) {
                // 时间范围并起来，界面上这一段仍然从第一次说的时候开始。
                last.end = max(last.end, segment.end)
                if trimmed.count > last.text.trimmingCharacters(in: .whitespacesAndNewlines).count {
                    last.text = trimmed
                    last.confidence = max(last.confidence, segment.confidence)
                }
                result[result.count - 1] = last
                continue
            }
            segment.text = trimmed
            result.append(segment)
        }
        return result
    }

    /// 一句之内连续重复同一个片段 ≥ `threshold` 次、且总跨度 ≥ `minimumSpan` → 只留一次。
    ///
    /// 逐长度扫描（1~12 字）而不是上正则：要顺手挡掉两件事 ——
    /// ① `1000` 里有连着的三个 0，正则替换会把它变成 `10`，所以要求重复单元里
    /// **至少有一个汉字**；② 会上的 `对对对` 是真在表态，所以还要求总跨度够长。
    private static func collapseInnerRepeats(
        _ text: String,
        threshold: Int,
        minimumSpan: Int
    ) -> String {
        var characters = Array(text)
        for length in 1...12 {
            var index = 0
            var output: [Character] = []
            output.reserveCapacity(characters.count)

            while index < characters.count {
                var repeats = 1
                while index + length * (repeats + 1) <= characters.count {
                    let previous = characters[(index + length * (repeats - 1))..<(index + length * repeats)]
                    let next = characters[(index + length * repeats)..<(index + length * (repeats + 1))]
                    if previous.elementsEqual(next) {
                        repeats += 1
                    } else {
                        break
                    }
                }

                let unit = characters[index..<min(index + length, characters.count)]
                if repeats >= threshold, length * repeats >= minimumSpan, unit.contains(where: isCJK) {
                    output.append(contentsOf: unit)
                    index += length * repeats
                } else {
                    output.append(characters[index])
                    index += 1
                }
            }
            characters = output
        }
        return String(characters)
    }

    /// 两段文本是不是「同一句话」。
    ///
    /// 判等前先归一化（去空白、去标点），因为 whisper 同一句话在两次输出里
    /// 标点和空格常常不一样。
    private static func isRepeat(_ lhs: String, _ rhs: String, minimumLength: Int) -> Bool {
        let left = normalizedForComparison(lhs)
        let right = normalizedForComparison(rhs)
        guard left.count >= minimumLength, right.count >= minimumLength else { return false }
        if left == right { return true }
        // 逐步"长大"的重复（`我们来看` → `我们来看这个`）也很常见，认一个方向的前缀关系。
        return left.hasPrefix(right) || right.hasPrefix(left)
    }

    private static func normalizedForComparison(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .punctuationCharacters)
    }

    // MARK: - 2 术语替换

    private static func applyTerminology(
        _ segment: TranscriptSegment,
        _ table: [String: String]
    ) -> TranscriptSegment {
        guard !table.isEmpty else { return segment }
        var segment = segment
        var text = segment.text
        // 长的先替，避免短词把长词的一部分先改掉。
        for (wrong, right) in table.sorted(by: { $0.key.count > $1.key.count })
        where text.contains(wrong) {
            text = text.replacingOccurrences(of: wrong, with: right)
        }
        segment.text = text
        return segment
    }

    // MARK: - 3 按句合并

    /// 把碎段并成句子级的段：遇到句末标点就断，或者到 `limit` 字断开。
    ///
    /// 时间取「第一段的起点 + 最后一段的终点」，所以点某一段跳播放仍然落在正确的位置，
    /// 只是粒度从 15 字变成一句。置信度取两者较低的那个（保守）。
    private static func mergeBySentence(
        _ segments: [TranscriptSegment],
        limit: Int
    ) -> [TranscriptSegment] {
        let sentenceEnders: Set<Character> = ["。", "！", "？", "；", "…", "!", "?", ";"]

        var result: [TranscriptSegment] = []
        var buffer: TranscriptSegment?

        for segment in segments {
            guard var current = buffer else {
                buffer = segment
                continue
            }
            let alreadyEnded = current.text.last.map { sentenceEnders.contains($0) } ?? true
            let candidate = current.text + segment.text
            if !alreadyEnded, current.speaker == segment.speaker, segment.start <= current.end + 1, candidate.count <= limit {
                current.text = candidate
                current.end = max(current.end, segment.end)
                current.confidence = min(current.confidence, segment.confidence)
                buffer = current
            } else {
                result.append(current)
                buffer = segment
            }
        }
        if let buffer { result.append(buffer) }
        return result
    }

    // MARK: - 4 丢低置信（优先级最低：只占 0.6%）

    /// 只丢「又短又没信心」的段。并句之后，一段里只要有一两个字听错，
    /// 整段置信度就被拉到门槛以上，所以这一步实际上只清理那些没并进任何句子的碎渣。
    private static func dropLowConfidence(
        _ segments: [TranscriptSegment],
        options: Options
    ) -> [TranscriptSegment] {
        segments.filter { segment in
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            // 纯标点段没有任何信息。
            if trimmed.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) { return false }
            if trimmed.count <= options.dropMaxLength, segment.confidence < options.dropConfidence {
                return false
            }
            return true
        }
    }

    // MARK: - 工具

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
