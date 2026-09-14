import Foundation

/// 双声道（P2-2a）两路转写的合并：把「麦克风一路（我方）」与「系统声音一路（对方）」
/// 拼回同一条时间线，并逐段打上说话人。
///
/// ## 为什么必须是纯函数 + 单测
///
/// 它决定的正是**用户可见的说话人归属**：把人说成对方、把对方说成我，
/// 转写正文读起来完全自然，**永远没人发现**（和"方向型转换表写反"是同一类事故）。
/// 而真实的两路音频在本机与 CI 上都造不出来，录音那一半没法自动验证 ——
/// 所以至少把这一半做成可证的：写成录音类里的私有方法的话，`swift test` 根本跑不到它。
///
/// ## 它在防什么
///
/// 外放（不戴耳机）开会时，**麦克风会把对方的声音一起收进来** —— 同一句话在两路里
/// 各出现一次，甚至转写得一模一样。不处理的话逐字稿会整段重复，而且重复的那一条
/// 归属是错的（对方的话被标成我方）。判据是「时间上重叠 + 文本是同一句话」。
///
/// 反过来，**真的两个人同时说话**（"对，我就是说那个"）在时间上也重叠，
/// 但文本不同 —— 这种必须两条都留下：宁可重复，也不能把真实发言丢掉。
enum TranscriptMerger {
    /// 串音判定线：两段的**重叠时长**占较短那段的**比例**超过它，才进入"是不是同一句话"的判断。
    ///
    /// 取 0.6 而不是 0.5：正常的接话都会有一点点重叠，线压太低会把
    /// **真的两人同时说话**错当串音。注意这一条只是**必要条件**，
    /// 真正决定丢不丢的是下面的文本相似度。
    static let crosstalkOverlapRatio = 0.6

    /// 走"相似"这条路的最短长度。太短的（"嗯"、"对"）只认**逐字相同**，
    /// 否则「嗯」和「嗯嗯」会被判成同一句，白丢一次发言。
    private static let minimumTextLengthForSimilarity = 4

    /// 文本相似线：较短那句里有多大比例的字符能在另一句里找到。
    private static let similarityThreshold = 0.6

    /// 合并两路转写。
    ///
    /// - Parameters:
    ///   - local: 麦克风那一路（本机用户）。
    ///   - remote: 系统声音那一路（会议软件里传来的对方）。
    /// - Returns: 按时间排序的一路逐字稿，每段都带 `speaker`。
    ///
    /// 输入里原本的 `speaker` 会被**覆盖**：调用点传进来的就是刚转出来的两路裸结果，
    /// 说话人由**音轨来源**决定，不由上游数据决定。
    static func merge(
        local: [TranscriptSegment],
        remote: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let candidates = tagged(local, as: .local) + tagged(remote, as: .remote)
        guard !candidates.isEmpty else { return [] }

        var merged: [TranscriptSegment] = []
        for candidate in candidates.sorted(by: isOrderedBefore) {
            guard let last = merged.last else {
                merged.append(candidate)
                continue
            }
            // 串音重复就在原地收敛成一条：位置不动，时间线不会被改写。
            if let resolved = resolve(last: last, next: candidate) {
                merged[merged.count - 1] = resolved
            } else {
                merged.append(candidate)
            }
        }
        return merged
    }

    /// 这一路转写里有没有**能算数**的内容（有效字符 ≥ 1）。
    ///
    /// 用来判断"这一路要不要真的跑一次转写"：全程静音的通道跑 whisper 不仅白花一半时间，
    /// 还会在静音上**幻觉出一整段话**（whisper 的经典毛病），比不转更糟。
    static func hasSpeech(_ segments: [TranscriptSegment]) -> Bool {
        segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - 内部

    private static func tagged(
        _ segments: [TranscriptSegment],
        as speaker: TranscriptSpeaker
    ) -> [TranscriptSegment] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.end >= segment.start else { return nil }
            var copy = segment
            copy.text = text
            copy.speaker = speaker
            return copy
        }
    }

    /// 全序：起点 → 说话人（我方在前）→ 终点 → 文本。
    ///
    /// 必须是**全序**，不能只按起点排：同一起点（两路都从 0 开始、或同一句串音）
    /// 的比较结果若不确定，同一份输入会给出两种逐字稿，而两者都"看起来对"。
    private static func isOrderedBefore(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.speaker != rhs.speaker { return speakerRank(lhs.speaker) < speakerRank(rhs.speaker) }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.text < rhs.text
    }

    private static func speakerRank(_ speaker: TranscriptSpeaker?) -> Int {
        switch speaker {
        case .local: return 0
        case .remote: return 1
        case nil: return 2
        }
    }

    /// 两条要不要收敛成一条；不要就返回 nil。
    private static func resolve(
        last: TranscriptSegment,
        next: TranscriptSegment
    ) -> TranscriptSegment? {
        // 同一路内部的重复（whisper 在长静音上自重复）不归这里管 ——
        // 那是单路分块拼接的老问题，由 `MeetingStore.mergeSegments` + `TranscriptCleaner` 处理。
        guard last.speaker != next.speaker else { return nil }

        let overlap = min(last.end, next.end) - max(last.start, next.start)
        guard overlap > 0 else { return nil }
        let shorter = min(last.end - last.start, next.end - next.start)
        guard shorter > 0, overlap / shorter >= crosstalkOverlapRatio else { return nil }

        guard isSameSpeech(last.text, next.text) else { return nil }
        return preferred(between: last, and: next)
    }

    /// 同一句话在两路里的两份转写，留哪一份。
    ///
    /// 置信度优先，其次长的（转写更完整），再平手就留排在前面的那条 ——
    /// 也就是我方。全平手时必须有确定答案，不能"看哪条先到"。
    private static func preferred(
        between last: TranscriptSegment,
        and next: TranscriptSegment
    ) -> TranscriptSegment {
        if next.confidence > last.confidence { return next }
        if next.confidence < last.confidence { return last }
        if next.text.count > last.text.count { return next }
        return last
    }

    private static func isSameSpeech(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        if left == right { return true }
        guard min(left.count, right.count) >= minimumTextLengthForSimilarity else { return false }
        return containment(left, right) >= similarityThreshold
    }

    /// 较短那句里有多大比例的字符能在另一句里找到（按字数计，不是集合）。
    private static func containment(_ lhs: String, _ rhs: String) -> Double {
        var remaining: [Character: Int] = [:]
        for character in lhs { remaining[character, default: 0] += 1 }

        var shared = 0
        for character in rhs {
            guard let count = remaining[character], count > 0 else { continue }
            remaining[character] = count - 1
            shared += 1
        }
        return Double(shared) / Double(max(1, min(lhs.count, rhs.count)))
    }

    /// 去掉空白与标点后的正文。`MeetingStore.mergeSegments` 判"同一句话"也用它 ——
    /// 同一个判据不能有两份实现（本项目铁律）。
    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .punctuationCharacters)
    }
}
