import Foundation

/// 把一场会议变成**能带走的东西**。
///
/// 存在的理由：这个 App 已经把最难的部分做完了（本机转写 + 结构化纪要），
/// 但产出一直困在窗口里 —— 用户只能截屏或者手抄。这一层专门负责「送出去」。
///
/// **为什么必须是纯函数**：导出内容里有好几处"看着没问题、实际会出错"的地方 ——
/// 标题带 `/` 会写出非法文件名、只有时间锚没有正文的要点会渲染成一个孤零零的时刻、
/// 老会话没有 `speaker` 时会写出一个空括号。这些只有单测能拦住。
///
/// **为什么钉死在 Markdown**：`##` / `- ` / `- [ ]` 在飞书文档、腾讯文档、Notion 里
/// 粘贴即渲染；纯文本会丢掉层级；导出成 PDF / Word 又会把「粘进文档再编辑」这条路堵死。
enum MeetingExporter {

    // MARK: - 对外两个入口

    /// 整场导出的正文。
    ///
    /// 顺序刻意与速览页的漏斗一致（结论 → 要点 → 决策 → 待办 → 待确认 → 概述 → 经过），
    /// 逐字稿放最后当**附录** —— 收件人先看结论，需要核对时再往下翻。
    static func markdown(for session: MeetingSession) -> String {
        var blocks: [String] = []

        blocks.append("# \(displayTitle(for: session))")
        blocks.append(metaLine(for: session))

        // 整理没成 / 结果不完整时，把原因写在最前面。
        // 不写的话，收件人会把「只有逐字稿」当成"这场会确实什么都没定"——
        // 那是**一个错误的结论**，比缺内容更糟。
        if let notice = trimmed(session.analysis.noticeMessage) {
            blocks.append("> ⚠️ \(notice)")
        }

        if let headline = trimmed(session.analysis.headline) {
            blocks.append(section("一句话结论", body: headline))
        }

        let bullets = session.analysis.parsedOverviewBullets.filter { !$0.text.isEmpty }
        if !bullets.isEmpty {
            let lines = bullets.map { bullet -> String in
                guard let seconds = bullet.seconds else { return "- \(bullet.text)" }
                return "- [\(seconds.clockLabel)] \(bullet.text)"
            }
            blocks.append(section("要点", body: lines.joined(separator: "\n")))
        }

        if !session.analysis.decisions.isEmpty {
            let lines = session.analysis.decisions.map { item -> String in
                var line = "- **\(item.label)**"
                var tags: [String] = []
                if let stamp = item.timestamp { tags.append("时间 \(stamp.clockLabel)") }
                if !tags.isEmpty { line += "（\(tags.joined(separator: " · "))）" }
                if let evidence = trimmed(item.evidence) {
                    line += "\n  - 依据：\(evidence)"
                }
                return line
            }
            blocks.append(section("决策与结论", body: lines.joined(separator: "\n")))
        }

        if !session.analysis.actions.isEmpty {
            let lines = session.analysis.actions.map { item -> String in
                // `- [ ]` 是 Markdown 待办框：粘进 Notion / 飞书文档后可以直接勾。
                var line = "- [ ] \(item.label)"
                var tags: [String] = []
                if let owner = trimmed(item.owner) { tags.append("负责人 \(owner)") }
                if let due = trimmed(item.dueText) { tags.append("截止 \(due)") }
                if let priority = item.priority { tags.append("\(priority.friendlyLabel)优先") }
                if let stamp = item.timestamp { tags.append("时间 \(stamp.clockLabel)") }
                if !tags.isEmpty { line += "（\(tags.joined(separator: " · "))）" }
                if let evidence = trimmed(item.evidence) {
                    line += "\n  - 依据：\(evidence)"
                }
                return line
            }
            blocks.append(section("待办", body: lines.joined(separator: "\n")))
        }

        let questions = (session.analysis.openQuestions ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !questions.isEmpty {
            blocks.append(section("待确认", body: questions.map { "- \($0)" }.joined(separator: "\n")))
        }

        if let overview = trimmed(session.analysis.overviewText) {
            blocks.append(section("会议概述", body: overview))
        }

        if !session.analysis.timeline.isEmpty {
            let lines = session.analysis.timeline.map { chunk -> String in
                var line = "- **[\(chunk.rangeLabel)]** \(chunk.summary)"
                if let evidence = trimmed(chunk.evidence) {
                    line += "\n  - 依据：\(evidence)"
                }
                return line
            }
            blocks.append(section("经过", body: lines.joined(separator: "\n")))
        }

        if let appendix = transcriptAppendix(for: session) {
            blocks.append(appendix)
        }

        blocks.append("---\n\n由 MeetingScribe 导出 · \(Date.now.formatted(date: .numeric, time: .shortened))")
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// 默认文件名：`2026-09-15-客户评审会.md`。
    ///
    /// 日期在前是按**文件列表的排序**来的 —— 同一个项目的会按时间排成一列，
    /// 标题在前的话，一周里不同的会会散开。
    static func fileName(for session: MeetingSession) -> String {
        "\(dayStamp(for: session.createdAt))-\(sanitizedTitle(for: session)).md"
    }

    /// `2026-09-15`。
    ///
    /// **刻意不用 `formatted(.dateTime…)`**：那个输出跟系统地区走，
    /// 中文环境给 `2026/09/15`、英文环境给 `09/15/2026` —— 同一天两台机器导出的
    /// 文件名顺序会**倒过来**（年月日 vs 月日年），按文件名排序时一片混乱。
    /// 自己按年月日拼，任何地区下结果一致。
    private static func dayStamp(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    // MARK: - 内部

    /// 文件名里不能出现的字符（macOS + 兼容 Windows 与各类云盘）。
    ///
    /// 顺带把换行和制表符也换掉：它们不会让写入失败，但会让文件名
    /// 在 Finder 里显示成两行、在网盘里变成一堆空格，难认且难搜。
    private static let illegalFileNameCharacters = CharacterSet(
        charactersIn: "/\\:*?\"<>|\n\r\t"
    )

    private static func sanitizedTitle(for session: MeetingSession) -> String {
        let raw = displayTitle(for: session)
        let replaced = raw.components(separatedBy: illegalFileNameCharacters)
            .joined(separator: "-")
        // 连续的分隔符压成一个。
        //
        // 不压的话，「上半场\n\t下半场」会变成「上半场--下半场」——
        // 两个破折号连在一起看着像手抖打错了，而且原文里本来可能就有一个破折号，
        // 读的人分不清哪个是标题自带的。
        let collapsed = collapsingRepeatedDashes(in: replaced)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 首尾的点会让文件在 Finder 与部分网盘里被当成隐藏文件。
        let trimmedDots = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        let fallback = trimmedDots.isEmpty ? "未命名会议" : trimmedDots
        // 标题过长会撞上文件系统的 255 字节上限（中文一个字 3 字节，
        // 60 个字就到 180 字节，再挂上日期前缀就危险了）。
        return String(fallback.prefix(60))
    }

    /// 把连续两个以上的 `-` 压成一个 `-`（单个 `-` 原样保留）。
    private static func collapsingRepeatedDashes(in text: String) -> String {
        var result = ""
        var previousWasDash = false
        for character in text {
            if character == "-" {
                if previousWasDash { continue }
                previousWasDash = true
            } else {
                previousWasDash = false
            }
            result.append(character)
        }
        return result
    }

    private static func displayTitle(for session: MeetingSession) -> String {
        let raw = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "未命名会议" : raw
    }

    private static func metaLine(for session: MeetingSession) -> String {
        var parts = [session.createdAt.formatted(date: .numeric, time: .shortened)]
        if let duration = session.duration { parts.append("时长 \(duration.clockLabel)") }
        if let model = session.analysis.modelLabel { parts.append("整理模型 \(model)") }
        return "_\(parts.joined(separator: " · "))_"
    }

    private static func section(_ title: String, body: String) -> String {
        "## \(title)\n\n\(body)"
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 逐字稿附录。
    ///
    /// 优先用**分段**（带起止秒与说话人）而不是 `transcriptText` ——
    /// 后者是一整块文本，粘进文档后每段都连在一起，没法定位到某一句话。
    /// 只有在分段为空（老会话或转写未完成）时才退回整块文本。
    private static func transcriptAppendix(for session: MeetingSession) -> String? {
        if !session.transcriptSegments.isEmpty {
            let lines = session.transcriptSegments.map { segment -> String in
                // 说话人缺失时**整个括号都不出现**，不写「（不明）」——
                // 那会变成一条读者必须解释的假信息（同 `materialLine` 的判断）。
                //
                // 括号拼在正文**紧前面**（不是分开两段再 join）：中间多一个空格的话，
                // 中文逐字稿会读成「（我方） 这个价格可以」，像是排版漏了一个字。
                let speakerPart = segment.speaker.map { "（\($0.displayName)）" } ?? ""
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return "- [\(segment.start.clockLabel)] \(speakerPart)\(text)"
            }
            return section("原文（逐字稿）", body: lines.joined(separator: "\n"))
        }
        guard let text = trimmed(session.transcriptText) else { return nil }
        return section("原文（逐字稿）", body: text)
    }
}
