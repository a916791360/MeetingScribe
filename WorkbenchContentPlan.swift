import Foundation

/// 结果区的内容块 —— **「哪块内容归哪一页」的唯一事实来源**。
///
/// ## 为什么要有这张表
///
/// 这两页原来靠**详略**分家：速览列前 3 条、行尾一颗「查看全部 ›」跳到纪要看全量。
/// 那等于向用户声明"这两页装的是同一份东西，只是长度不同" —— 于是同一份决策清单
/// 在两页各渲染一遍。实测「要点」与决策/待办的语义重合 **平均 73%、86% 的要点重合过半**，
/// 一场典型会议用户要读的重复内容 ≈ 25 条清单 × 2 + 7 条要点。
/// 用户那句「两个里面都有待办，重复了没意义」，是**正确的阅读反应**。
///
/// 改成按**形态**分工之后，两页的内容集合必须**互不相交**：
/// 速览只放清单（这场会产出了什么），纪要只放叙述（结论是怎么定下来的）。
///
/// ## 判据为什么落成数据而不是两处 `if`
///
/// 判据一旦分散在两个 View 里各写各的，迟早又漂回重叠（本项目已经栽过同类的跟头：
/// "同一件事写在多处＝静默不一致的温床"）。所以：
///   · **渲染顺序**由下面两个数组驱动（`ForEach` 遍历，顺序即页面上从上到下的顺序）；
///   · **块的渲染**由 `switch` 承担 —— 漏掉一个块，编译器直接报错，不会静默消失；
///   · **归属本身**由 `WorkbenchContentPlanTests` 钉住：两页集合交集为空、并集无遗漏、
///     每个块的 `tab` 与它所在的顺序表一致。
///
/// 一句话判据（拿不准某块归哪页时问它）：
/// **它回答的是「产出了什么」还是「怎么来的」？** 前者归速览，后者归纪要。
enum WorkbenchContentBlock: String, CaseIterable, Hashable {
    /// 一句话结论（`MeetingAnalysis.headline`）。
    case headline
    /// 要点（`MeetingAnalysis.overviewBullets`）。
    case bullets
    /// 决策与结论（`MeetingAnalysis.decisions`）。
    case decisions
    /// 待办（`MeetingAnalysis.actions`）。
    case actions
    /// 风险与阻塞（`MeetingAnalysis.risks`）。
    case risks
    /// 待确认（`MeetingAnalysis.openQuestions`）。
    case openQuestions
    /// 会议概述导语（`MeetingAnalysis.overviewText`）。
    case overviewLead
    /// 成文纪要正文（`MeetingAnalysis.minutesText`）。
    case minutesProse
    /// 时间导航（`MeetingAnalysis.timeline`）。
    case timeline

    /// 主展示位。**每个块有且只有一个。**
    ///
    /// 另一页若需要它，只能用指针（计数 + 跳转），不能来第二份渲染 ——
    /// 这正是"清单在速览列一遍、纪要继续列一遍"当初的做法，也是重复的源头。
    var tab: MeetingResultTab {
        switch self {
        case .headline, .bullets, .decisions, .actions, .risks, .openQuestions, .overviewLead:
            return .overview
        case .minutesProse, .timeline:
            return .minutes
        }
    }

    /// 速览页的展示顺序：**结论 → 要点 → 决策 → 待办 → 风险 → 待确认 → 概述**。
    ///
    /// 前六块是"读完就能走"的索引，导语（200~400 字）压在最后当正文 ——
    /// 它摆在最前面会把索引全部推到折线以下（这条判断从 v0.9 起没变，只是
    /// 现在它不再需要跟"时间轨"争位置了，时间轨已经归纪要）。
    ///
    /// 风险紧跟在待办之后：**"要做什么"和"什么会挡着"是同一个决策链条的两端**，
    /// 分开摆会让读者先看完行动、再翻到别处才知道有阻塞。
    static let overviewOrder: [WorkbenchContentBlock] = [
        .headline,
        .bullets,
        .decisions,
        .actions,
        .risks,
        .openQuestions,
        .overviewLead
    ]

    /// 纪要页的展示顺序：**正文 → 时间导航**。
    ///
    /// 只装叙述。决议与待办**在正文里**被说清楚（`minutesPrompt` 明确要求
    /// "结论和待办本身要写进正文里说清楚"），但不再给第二遍**清单形态** ——
    /// 速览给"可勾选、可代入的条目"，纪要给"可阅读、可归档的文档"。
    static let minutesOrder: [WorkbenchContentBlock] = [
        .minutesProse,
        .timeline
    ]

    /// 某一页的展示顺序。原文页不参与（它直接渲染逐字稿）。
    static func order(for tab: MeetingResultTab) -> [WorkbenchContentBlock] {
        switch tab {
        case .overview: return overviewOrder
        case .minutes: return minutesOrder
        case .original: return []
        }
    }
}

/// Bound rendered rows for very long imports; all source segments remain available
/// to playback, editing, copying and export. Page boundaries never drop a segment.
struct TranscriptPage: Equatable {
    static let size = 500
    let index: Int
    let count: Int
    let range: Range<Int>

    init(total: Int, requestedIndex: Int) {
        let total = max(0, total)
        count = total <= 1000 ? 1 : total / Self.size + (total % Self.size == 0 ? 0 : 1)
        index = min(max(0, requestedIndex), count - 1)
        let start = count == 1 ? 0 : index * Self.size
        range = start..<min(total, start + (count == 1 ? total : Self.size))
    }

    static func index(containing segmentIndex: Int, total: Int) -> Int {
        total <= 1000 ? 0 : max(0, segmentIndex) / size
    }
}
