import XCTest
@testable import MeetingScribe

/// 守住文档页的几条**几何等式**。
///
/// 这几条都是"改一个数、别处悄悄错位"的类型 —— 界面上不会崩，只会变得不齐，
/// 而"不齐"正是这个项目反复返工的那一类问题（条目被时间轨推着往右内缩、
/// 加个容器把右边界改了、整列宽到一行 60 字）。所以它们值得几个断言，
/// 而不是靠下次截图时肉眼发现。
final class LayoutTokenTests: XCTestCase {

    /// 散文块容器：外宽 = 行宽 + 两侧内衬 = **整个结构列**。
    ///
    /// 这条等式是"盒子的左右边框跟 Tab 发丝线、章节分隔线落在同一条竖线上"的
    /// 全部依据。上一版容器是 720（= 680 + 40）：左沿在结构线上，
    /// 右沿却落在 1141.5 —— 比结构列的 1221 短 79.5pt，成了那一页上的第三条右边界。
    func testProsePanelSpansTheStructuralColumnExactly() {
        XCTAssertEqual(
            AppTheme.proseLineWidth + AppTheme.space5 * 2,
            AppTheme.contentColumn,
            accuracy: 0.001,
            "容器的外沿必须正好是结构列，否则盒子的右边框会飘在结构线之外"
        )
    }

    /// 散文比结构列窄一档：它是有背景、有 1pt 边框的**面**，字不能贴着框线站。
    ///
    /// 条目行反过来 —— 它们没有面也没有框，所以字直接铺满结构列（见下一条）。
    func testProseLineLeavesThePanelItsPadding() {
        XCTAssertLessThan(
            AppTheme.proseLineWidth,
            AppTheme.contentColumn,
            "带内衬的盒子，里面的字必须比外沿窄，否则框读起来是「挤」的"
        )
    }

    /// **条目行必须正好铺满结构列**（v0.6.2 第二轮）。
    ///
    /// 守的是用户报的那次返工：「内容是非常往右的」。上一版三页的条目左边
    /// 各有一条 96pt 的时间轨，正文从 `轨宽 + 轨距 = 112pt` 之后才起笔，
    /// 而「决策与结论」这类章节标题在结构列左沿 —— 两者错开 112pt，
    /// 整块内容看着就是"缩在右边"。
    ///
    /// 轨撤掉之后，条目正文、时间戳、依据、行间分隔线的起笔线全部落在结构列左沿；
    /// 这条断言守的是"行宽没有再被谁改小"—— 一旦被改小，
    /// 就等于有人又把条目推向了右边。
    func testDocumentRowsFillTheStructuralColumn() {
        XCTAssertEqual(
            AppTheme.documentRowWidth,
            AppTheme.contentColumn,
            accuracy: 0.001,
            "条目行窄于结构列 = 条目被推向右，与章节标题错开"
        )
    }

    /// 结构列有**上限**，不许再涨回 920。
    ///
    /// 920 那一档的教训是"15pt 中文一行排到 60 字开外，眼睛要横扫一整个屏幕才换行"
    /// （用户原话「信息不易阅读」）。所以这个数不是随手取的：
    /// 800pt 对 15pt 中文约 53 字／行，已经贴着舒适区上沿。
    /// 下限则防止有人"为了精致"把它收成一条窄栏。
    func testStructuralColumnStaysInsideTheComfortableReadingBand() {
        XCTAssertLessThanOrEqual(
            AppTheme.contentColumn, 820,
            "再宽就一行 60 字，眼睛兜不住一整行"
        )
        XCTAssertGreaterThanOrEqual(
            AppTheme.contentColumn, 640,
            "再窄就不像文档了，断行过碎"
        )
    }
}
