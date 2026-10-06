import Foundation

/// 逐字稿**就地编辑**（方案 P1-4）的纯逻辑层：定位一段、归一化用户输入、落定标记。
///
/// 全部是纯函数、无副作用：不碰盘、不碰网络。目的是让「用户改了一句话」这件事
/// 能被单测钉死 —— 它要写回**用户自己看得见的数据**，判错一次就是把人家的逐字稿改坏，
/// 而这类错误不会报错（改坏了它照样能存、照样能渲染，只是内容不对了）。
enum TranscriptEditor {

    /// 一次编辑尝试的结果。
    ///
    /// **分成三态而不是 `[TranscriptSegment]`**：不区分「没改」与「改了」的话，
    /// 用户点一下保存、什么都没动，也会写盘 + 打上「已人工校正」——
    /// 于是页眉改口、段尾徽标从置信度变成「已校正」，全都发生在一次无操作的点击之后。
    /// 而且每个会话每启动一次都可能被"改"一次（见 `needsMaterialGateRepair` 的幂等教训）。
    enum Outcome: Equatable, Sendable {
        /// 改到了，落定后的完整数组。
        case saved([TranscriptSegment])
        /// 归一化之后与原文本一致 —— 一个字节都不该动。
        case unchanged
        /// 输入不可接受，附给用户看的理由。
        case rejected(String)
    }

    /// 「这段输入算不算一次有效改动」的判定。
    ///
    /// **只有这一处**。界面拿它决定「保存」按钮亮不亮，`apply` 拿它决定写不写盘 ——
    /// 两处各写一份的话，迟早会出现「按钮亮着、点下去什么都没发生」
    /// （或者反过来，按钮灰着、其实能改），而这两种都不报错。
    enum Verdict: Equatable {
        /// 有效，附归一化之后的文本。
        case effective(String)
        case unchanged
        case rejected(String)
    }

    /// 用户输入归一化。
    ///
    /// 两件事：① 首尾空白去掉；② **内部的换行折成一个空格**。
    /// 编辑器允许折行显示（长句在单行里横向滚动没法用），但一段逐字稿是**一段话**，
    /// 不是多段 —— 让换行进到数据里，会得到「一段文本自己带着换行符」这种
    /// 谁也不知道该怎么渲染的东西（页面上看起来还好，导出/喂给模型时是乱的）。
    static func normalize(_ raw: String) -> String {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let joined = lines
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 归一化之后，这次输入到底算什么。`existing` 是这一段现在的文本。
    static func verdict(for text: String, against existing: String) -> Verdict {
        let normalized = normalize(text)
        guard !normalized.isEmpty else {
            // **不允许把一段改成空**：删掉一段等于删掉那几十秒音频在纸面上的存在，
            // 而每一段背后都还挂着时间戳与真实录音。
            // 项目里「逐字稿任何时候都不删」这条是硬约束（见 2C）。
            return .rejected("这一段不能改成空。要丢掉整段，请连同录音一起删除这场会议。")
        }
        guard normalized != existing else { return .unchanged }
        return .effective(normalized)
    }

    /// 把 `segmentID` 那一段的文本改成 `text`。
    ///
    /// - 找不到这一段 → `.unchanged`（界面上的"正在编辑"与数据不同步时，
    ///   静默什么都不做，比对着错误的段写进去强）。
    static func apply(
        text: String,
        to segments: [TranscriptSegment],
        segmentID: UUID,
        at date: Date = Date()
    ) -> Outcome {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else {
            return .unchanged
        }

        switch verdict(for: text, against: segments[index].text) {
        case let .rejected(reason):
            return .rejected(reason)
        case .unchanged:
            return .unchanged
        case let .effective(normalized):
            var updated = segments
            updated[index].text = normalized
            updated[index].manuallyEditedAt = date
            return .saved(updated)
        }
    }

    /// 被人工改过的段数。页眉那句「已人工校正 N 处」用它。
    static func editedCount(in segments: [TranscriptSegment]) -> Int {
        segments.reduce(into: 0) { count, segment in
            if segment.manuallyEditedAt != nil { count += 1 }
        }
    }
}
