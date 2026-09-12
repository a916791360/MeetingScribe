import XCTest
@testable import MeetingScribe

/// 守住「转写中」进度条的显示纪律。这个估算器只有三条规则，
/// 但三条都是**用户肉眼能看出问题**的：
///
/// - 回缩一次 → 进度条倒退，看着像"重头再来"；
/// - 越界一次 → 冲进下一段的区间，段真完成时反而"倒吸"；
/// - 提前猜 → 第一段还没跑完就给一个乱跳的假数。
///
/// 所以每条规则单独一个用例，改坏了立刻红。
final class ProcessingProgressEstimatorTests: XCTestCase {

    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func progress(
        base: Double,
        completedChunks: Int,
        totalChunks: Int,
        chunkStartedAfter elapsedBeforeChunk: TimeInterval,
        elapsedInChunk: TimeInterval
    ) -> Double {
        let startedAt = origin
        let chunkStartedAt = origin.addingTimeInterval(elapsedBeforeChunk)
        return ProcessingProgressEstimator.displayProgress(
            base: base,
            completedChunks: completedChunks,
            totalChunks: totalChunks,
            startedAt: startedAt,
            chunkStartedAt: chunkStartedAt,
            now: chunkStartedAt.addingTimeInterval(elapsedInChunk)
        )
    }

    /// 规则 3：一段都没跑完时没有"平均段耗时"可用，不许猜。
    func testFirstChunkIsNotEstimated() {
        let value = progress(
            base: 0,
            completedChunks: 0,
            totalChunks: 4,
            chunkStartedAfter: 0,
            elapsedInChunk: 600
        )
        XCTAssertEqual(value, 0, accuracy: 1e-9)
    }

    /// 规则 1 的正向面：段内确实在往上爬（不再是"十分钟一动不动"）。
    func testAdvancesSmoothlyInsideChunk() {
        // 第 1 段实际用了 600 秒。现在第 2 段跑了 300 秒，
        // 平均段耗时 = 900/1 = 900，段内完成度 = 300/900 = 1/3。
        let value = progress(
            base: 0.25,
            completedChunks: 1,
            totalChunks: 4,
            chunkStartedAfter: 600,
            elapsedInChunk: 300
        )
        let expected = (1.0 + 1.0 / 3.0) / 4.0
        XCTAssertEqual(value, expected, accuracy: 1e-6)
        XCTAssertGreaterThan(value, 0.25, "必须跑在真实进度之上，否则等于没做")
    }

    /// 规则 2：跑再久也不能越过下一段的边界——否则段真完成时会倒吸。
    func testNeverCrossesNextChunkBoundary() {
        let base = 0.25
        let value = progress(
            base: base,
            completedChunks: 1,
            totalChunks: 4,
            chunkStartedAfter: 600,
            elapsedInChunk: 60 * 60 * 5
        )
        let ceiling = (1.0 + ProcessingProgressEstimator.maxIntraChunkFill) / 4.0
        XCTAssertEqual(value, ceiling, accuracy: 1e-9)
        XCTAssertLessThan(value, 0.5, "不能碰 2/4 这条线，那是第 2 段真完成的位置")
        XCTAssertGreaterThan(value, base)
    }

    /// 规则 1 的负向面：时间往前走，显示值只许不动或变大。
    func testNeverRetractsWhileTimeAdvances() {
        var previous = 0.0
        for elapsed in stride(from: 0.0, through: 3_000.0, by: 30.0) {
            let value = progress(
                base: 0.25,
                completedChunks: 1,
                totalChunks: 4,
                chunkStartedAfter: 600,
                elapsedInChunk: elapsed
            )
            XCTAssertGreaterThanOrEqual(value, previous, "第 \(elapsed) 秒时回缩了")
            previous = value
        }
    }

    /// 真实进度是**下限**：估算只许跑在它之上，绝不把它往下拉。
    /// （注意不是"相等"——段内插值本来就该略高于基线，这是它的全部意义。）
    func testRealProgressIsAlwaysTheFloor() {
        let base = 0.75
        let value = progress(
            base: base,
            completedChunks: 3,
            totalChunks: 4,
            chunkStartedAfter: 600,
            elapsedInChunk: 5
        )
        XCTAssertGreaterThanOrEqual(value, base)
        XCTAssertLessThan(value, 1.0)
    }

    /// 万一存盘里的进度比"已完成段数"更靠前（恢复会话时可能发生），
    /// 也不许把它往回收。
    func testDoesNotPullBackAnAlreadyAheadRealProgress() {
        let value = progress(
            base: 0.9,
            completedChunks: 1,
            totalChunks: 4,
            chunkStartedAfter: 600,
            elapsedInChunk: 5
        )
        XCTAssertEqual(value, 0.9, accuracy: 1e-9)
    }

    /// 转写已经收尾（或总段数未知）时不参与估算，直接透传真实值。
    func testStaysOutOfTheWayWhenNothingIsLeftToEstimate() {
        XCTAssertEqual(
            progress(base: 1, completedChunks: 4, totalChunks: 4, chunkStartedAfter: 0, elapsedInChunk: 300),
            1,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            progress(base: 0.4, completedChunks: 1, totalChunks: 0, chunkStartedAfter: 0, elapsedInChunk: 300),
            0.4,
            accuracy: 1e-9
        )
    }

    /// 时钟抖动出来的"平均段耗时"（<1 秒）不该被拿去做除数。
    func testIgnoresDegenerateAverageChunkDuration() {
        let value = progress(
            base: 0.25,
            completedChunks: 2,
            totalChunks: 4,
            chunkStartedAfter: 0.4,
            elapsedInChunk: 0.1
        )
        XCTAssertEqual(value, 0.25, accuracy: 1e-9)
    }
}
