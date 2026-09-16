import Foundation
import XCTest
@testable import MeetingScribe

/// E4 的单测：播放头 → 当前段。
///
/// 判据（`docs/产品迭代计划-v0.11.md` §2 E4）：
/// **0 秒 / 段间空隙 / 末尾 / 空数组** 四种边界都要有确定答案。
///
/// 其中「段间空隙」是最容易写错、也最容易被忽略的一种：whisper 在有停顿时不产段，
/// 空隙是**常态**。用区间判断（`start...end`）的话，播放到空隙里就会返回 nil，
/// 界面上表现为高亮闪一下消失又出现。
final class TranscriptPlayheadTests: XCTestCase {

    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String = "句子") -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, confidence: 0.9)
    }

    private var spoken: [TranscriptSegment] {
        [
            segment(0, 5, "第一句"),
            segment(8, 12, "第二句"),   // 5~8 是停顿（真实空隙）
            segment(20, 24, "第三句")   // 12~20 也是
        ]
    }

    func testEmptyArrayHasNoPlayhead() {
        XCTAssertNil([TranscriptSegment]().playheadIndex(at: 0))
        XCTAssertNil([TranscriptSegment]().playheadIndex(at: 999))
        XCTAssertNil([TranscriptSegment]().playheadSegment(at: 12))
    }

    /// 播放头还在第一句开口之前 —— 此刻没有"当前句"可言。
    ///
    /// 硬指到第一句上会让人以为已经听到了，而其实还没开始。
    func testTimeBeforeFirstSegmentReturnsNothing() {
        let segments = [segment(5, 9, "开口第一句")]
        XCTAssertNil(segments.playheadIndex(at: 0))
        XCTAssertNil(segments.playheadIndex(at: 4.99))
    }

    func testTimeExactlyAtStartSelectsThatSegment() {
        XCTAssertEqual(spoken.playheadIndex(at: 0), 0)
        XCTAssertEqual(spoken.playheadIndex(at: 8), 1)
        XCTAssertEqual(spoken.playheadIndex(at: 20), 2)
    }

    func testTimeInsideSegmentSelectsThatSegment() {
        XCTAssertEqual(spoken.playheadIndex(at: 3), 0)
        XCTAssertEqual(spoken.playheadIndex(at: 9.5), 1)
        XCTAssertEqual(spoken.playheadIndex(at: 23.9), 2)
    }

    /// **关键判据**：空隙里仍然高亮上一句，而不是没有高亮。
    func testGapKeepsThePreviousSegment() {
        XCTAssertEqual(spoken.playheadIndex(at: 5), 0)
        XCTAssertEqual(spoken.playheadIndex(at: 6.5), 0, "5~8 的停顿里应仍高亮第一句")
        XCTAssertEqual(spoken.playheadIndex(at: 7.99), 0)
        XCTAssertEqual(spoken.playheadIndex(at: 15), 1, "12~20 的停顿里应仍高亮第二句")
    }

    func testTimeAfterLastSegmentKeepsLastSegment() {
        XCTAssertEqual(spoken.playheadIndex(at: 24), 2)
        XCTAssertEqual(spoken.playheadIndex(at: 3600), 2)
        XCTAssertEqual(spoken.playheadSegment(at: 3600)?.text, "第三句")
    }

    func testSegmentIdentityIsReturned() {
        let segments = spoken
        XCTAssertEqual(segments.playheadSegment(at: 9)?.id, segments[1].id)
        XCTAssertEqual(segments.playheadSegment(at: 0)?.id, segments[0].id)
    }

    /// 二分查找的边界：每一个起点、以及每个起点前一点点，都要落到正确的段。
    ///
    /// 单独测"中间值"是测不出二分写错的 —— 写错时通常只在**区间端点**上错。
    func testBinarySearchMatchesLinearScanOnEveryBoundary() {
        let segments = (0..<200).map { index in
            segment(TimeInterval(index) * 7, TimeInterval(index) * 7 + 4, "第 \(index) 句")
        }

        func linear(_ time: TimeInterval) -> Int? {
            guard !segments.isEmpty, time >= segments[0].start else { return nil }
            var answer = 0
            for (index, item) in segments.enumerated() where item.start <= time {
                answer = index
            }
            return answer
        }

        // 每个起点、起点前 0.01 秒、段内中点、段尾
        for index in segments.indices {
            let start = segments[index].start
            for probe in [start - 0.01, start, start + 2, start + 3.99, start + 6.99] {
                XCTAssertEqual(
                    segments.playheadIndex(at: probe),
                    linear(probe),
                    "t=\(probe) 处二分与线性不一致"
                )
            }
        }
    }
}
