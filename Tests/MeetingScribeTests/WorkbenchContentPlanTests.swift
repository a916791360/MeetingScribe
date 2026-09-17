import XCTest
@testable import MeetingScribe

/// 「哪块内容归哪一页」的契约测试。
///
/// 这几条断言就是**两页不再重复**的判据本身。它们替代不了"渲染层真的没渲染两遍"
/// （SwiftUI 的 View 树没法断言），但足以钉住**判据**：
/// 只要有人把某块同时放进两页，或者新增了块却忘了归类，这里立刻红。
///
/// 为什么值得专门写一个文件：速览与纪要曾经靠**详略**分家（速览前 3 条 + 「查看全部 ›」
/// 跳纪要看全量），于是同一份决策清单在两页各渲染一遍，实测「要点」与清单的
/// 语义重合 73%、86% 的要点重合过半。判据一旦分散在两个 View 的 `if` 里，
/// 这次改完下次还会漂回去 —— 抽成数据 + 单测，是唯一能钉住它的办法。
final class WorkbenchContentPlanTests: XCTestCase {

    /// 交集为空 —— "两页不再重复"最直接的那条判据。
    func testTwoPagesShareNoContentBlock() {
        let overlap = Set(WorkbenchContentBlock.overviewOrder)
            .intersection(WorkbenchContentBlock.minutesOrder)
        XCTAssertTrue(overlap.isEmpty, "同一块内容出现在两页：\(overlap.map(\.rawValue).sorted())")
    }

    /// 并集必须覆盖所有块，且**不重不漏**。
    ///
    /// 漏一个块 = 它声明了归属却永远不会被渲染（用户看不到，而没有任何东西会报警）；
    /// 重复声明 = 同一页里同一块渲染两遍（"待办列两次"的原样重演）。
    func testEveryBlockIsDeclaredExactlyOnce() {
        let declared = WorkbenchContentBlock.overviewOrder + WorkbenchContentBlock.minutesOrder
        XCTAssertEqual(declared.count, Set(declared).count, "有块被重复声明")
        XCTAssertEqual(
            Set(declared),
            Set(WorkbenchContentBlock.allCases),
            "有块没有被任何一页声明"
        )
    }

    /// 顺序表里的块，`tab` 必须与它所在的那一页一致 —— 否则 `content(for:)` 会走进
    /// "归另一页"的 `EmptyView()` 分支，块**静默消失**（页面上少一块，不报错、不警告）。
    func testDeclaredOrderMatchesEachBlocksTab() {
        for block in WorkbenchContentBlock.overviewOrder {
            XCTAssertEqual(
                block.tab, .overview,
                "\(block.rawValue) 被放进速览顺序表，但它声明归「\(block.tab.title)」"
            )
        }
        for block in WorkbenchContentBlock.minutesOrder {
            XCTAssertEqual(
                block.tab, .minutes,
                "\(block.rawValue) 被放进纪要顺序表，但它声明归「\(block.tab.title)」"
            )
        }
    }

    /// `order(for:)` 与两个数组是同一份数据，不是各写一遍。
    func testOrderLookupMatchesTheDeclaredArrays() {
        XCTAssertEqual(WorkbenchContentBlock.order(for: .overview), WorkbenchContentBlock.overviewOrder)
        XCTAssertEqual(WorkbenchContentBlock.order(for: .minutes), WorkbenchContentBlock.minutesOrder)
    }

    /// 原文页不参与这套分配（它直接渲染逐字稿）。
    func testOriginalTabHasNoBlocks() {
        XCTAssertTrue(WorkbenchContentBlock.order(for: .original).isEmpty)
    }

    /// 清单类内容（决策 / 待办 / 风险）**只能有一个家**。
    ///
    /// 单独钉一条是因为用户的原始抱怨正是"两个里面都有待办" ——
    /// 这条断言就是那句话的可执行版本。
    func testChecklistsLiveOnlyOnTheOverviewTab() {
        for block in [WorkbenchContentBlock.decisions, .actions, .risks] {
            XCTAssertEqual(block.tab, .overview, "\(block.rawValue) 必须唯一归属速览页")
        }
    }

    /// 叙述类内容（成文正文 / 时间导航）归纪要页。
    func testNarrativeLivesOnlyOnTheMinutesTab() {
        for block in [WorkbenchContentBlock.minutesProse, .timeline] {
            XCTAssertEqual(block.tab, .minutes, "\(block.rawValue) 必须唯一归属纪要页")
        }
    }
}
