import XCTest
@testable import MeetingScribe

/// 守住速览「要点」的解析规则。
///
/// **为什么这段解析值得测**：`overviewBullets` 在存盘里是 `[String]`，
/// 而速览页要靠它把时间锚渲染成一颗**能跳播放的按钮**。解析一旦把锚读错，
/// 症状不是报错，而是"点了跳到 12 秒"这种只有真人听得出来的偏差；
/// 或者更安静的一种：整条要点的正文被吃掉，页面上凭空少一句。
///
/// 下面每一条都对应真实产出里见过的形状（见 2A 复评的 runs/*.json）。
final class OverviewBulletTests: XCTestCase {

    // MARK: - 正常形状

    func testParsesMinuteSecondAnchor() {
        let bullet = OverviewBullet.parse("[0:53] 与赵瑞梅协调 AI 方案，周六上线")
        XCTAssertEqual(bullet.seconds, 53)
        XCTAssertEqual(bullet.text, "与赵瑞梅协调 AI 方案，周六上线")
        XCTAssertTrue(bullet.hasAnchor)
    }

    /// 分钟补齐两位数，`[17:00]` 是最常见的形状。
    func testParsesLongMinuteAnchor() {
        let bullet = OverviewBullet.parse("[17:00] 周六上线版本增加首页工作台")
        XCTAssertEqual(bullet.seconds, 17 * 60)
        XCTAssertEqual(bullet.text, "周六上线版本增加首页工作台")
    }

    /// 超过一小时的会会出现 `[1:02:30]`，按 h:mm:ss 解。
    /// 这条如果解错，就会把 1 小时零 2 分当成 1 分 2 秒 —— 差三个数量级。
    func testParsesHourMinuteSecondAnchor() {
        let bullet = OverviewBullet.parse("[1:02:30] 下午的排期确认")
        XCTAssertEqual(bullet.seconds, 3750)
        XCTAssertEqual(bullet.text, "下午的排期确认")
    }

    /// 中文方括号也认（模型偶尔这么写）。
    func testAcceptsFullWidthBrackets() {
        let bullet = OverviewBullet.parse("【2:11】1.1 版本上产品学院")
        XCTAssertEqual(bullet.seconds, 131)
        XCTAssertEqual(bullet.text, "1.1 版本上产品学院")
    }

    // MARK: - 宽容边界

    /// 没有时间锚：整条留作正文，不吞任何字。
    func testKeepsPlainTextWithoutAnchor() {
        let bullet = OverviewBullet.parse("会上确认下周复测")
        XCTAssertNil(bullet.seconds)
        XCTAssertEqual(bullet.text, "会上确认下周复测")
        XCTAssertFalse(bullet.hasAnchor)
    }

    /// **锚不在句首就不当锚。** 模型偶尔会把时间写进句中
    /// （"…，在 [12:30] 决定了 X"）。若照切，前半句会整块消失。
    func testDoesNotTreatMidSentenceBracketAsAnchor() {
        let raw = "先确认预算，在 [12:30] 才定的方案"
        let bullet = OverviewBullet.parse(raw)
        XCTAssertNil(bullet.seconds)
        XCTAssertEqual(bullet.text, raw)
    }

    /// 括号里不是时间（比如「[待定] 供应商还没定」）→ 不是锚。
    func testRejectsNonTimeBracket() {
        let raw = "[待定] 供应商还没定"
        let bullet = OverviewBullet.parse(raw)
        XCTAssertNil(bullet.seconds)
        XCTAssertEqual(bullet.text, raw)
    }

    /// 只有锚、没有正文 → 正文是空串。**调用方据此跳过这一条**
    /// （渲染出来就是一个孤零零的时刻，比不画还糟）。
    func testEmptyTextWhenOnlyAnchorPresent() {
        let bullet = OverviewBullet.parse("[8:45]")
        XCTAssertEqual(bullet.seconds, 525)
        XCTAssertTrue(bullet.text.isEmpty)
    }

    /// 括号没闭合 → 不是锚，原样保留。
    func testUnclosedBracketIsNotAnchor() {
        let raw = "[12:30 这行没闭合"
        let bullet = OverviewBullet.parse(raw)
        XCTAssertNil(bullet.seconds)
        XCTAssertEqual(bullet.text, raw)
    }

    /// 越界的秒数按算术走，不做"合法性猜测"（59 秒制不是解析层的事）。
    /// 这里只需保证**不崩、不吞字**。
    func testDoesNotCrashOnLargeNumbers() {
        let bullet = OverviewBullet.parse("[99:99] 边界")
        XCTAssertEqual(bullet.seconds, 99 * 60 + 99)
        XCTAssertEqual(bullet.text, "边界")
    }

    // MARK: - 与 MeetingAnalysis 的接线

    /// `parsedOverviewBullets` 要能把整套要点都解出来，顺序不变。
    func testAnalysisParsesAllBulletsInOrder() {
        var analysis = MeetingAnalysis.empty
        analysis.overviewBullets = [
            "[0:00] 第一条",
            "[2:11] 第二条",
            "第三条没有锚",
        ]
        let parsed = analysis.parsedOverviewBullets
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.map(\.text), ["第一条", "第二条", "第三条没有锚"])
        XCTAssertEqual(parsed[0].seconds, 0)
        XCTAssertEqual(parsed[1].seconds, 131)
        XCTAssertNil(parsed[2].seconds)
    }

    /// 老会话没有这个键 → 空数组，不是崩。
    func testMissingBulletsYieldEmptyArray() {
        XCTAssertTrue(MeetingAnalysis.empty.parsedOverviewBullets.isEmpty)
    }

    /// `id` 要让 `ForEach` 稳定：同一批要点两次解析出同一个 id，
    /// 否则每次重绘都会把整列拆了重建（列表会闪）。
    func testIdentifiersAreStableAcrossParses() {
        let raw = ["[0:00] 第一条", "没有锚的一条"]
        let first = raw.map(OverviewBullet.parse).map(\.id)
        let second = raw.map(OverviewBullet.parse).map(\.id)
        XCTAssertEqual(first, second)
        // 两条内容不同 → id 也不能撞。
        XCTAssertNotEqual(first[0], first[1])
    }
}
