import XCTest
@testable import MeetingScribe

final class TranscriptPageTests: XCTestCase {
    func testAllSegmentsAppearExactlyOnceAcrossPageBoundaries() {
        for total in [0, 1, 999, 1000, 1001, 1499, 1500, 1501, 10000, 50000] {
            let first = TranscriptPage(total: total, requestedIndex: 0)
            let combined = (0..<first.count).flatMap { TranscriptPage(total: total, requestedIndex: $0).range }
            XCTAssertEqual(combined, Array(0..<total))
            if total > 1000 { XCTAssertLessThanOrEqual(first.range.count, TranscriptPage.size) }
        }
    }

    func testPlayheadSelectsPageThatActuallyContainsItsSegment() {
        for total in [1000, 1001, 1501, 50000] {
            for segment in [0, 499, 500, 999, total - 1] where segment < total {
                let index = TranscriptPage.index(containing: segment, total: total)
                XCTAssertTrue(TranscriptPage(total: total, requestedIndex: index).range.contains(segment))
            }
        }
    }

    func testRequestedPageClampsAfterResultCountChanges() {
        XCTAssertEqual(TranscriptPage(total: 50000, requestedIndex: -10).index, 0)
        XCTAssertEqual(TranscriptPage(total: 1001, requestedIndex: 99).range, 1000..<1001)
        XCTAssertEqual(TranscriptPage(total: 5, requestedIndex: 99).range, 0..<5)
        XCTAssertEqual(TranscriptPage(total: 0, requestedIndex: 99).range, 0..<0)
    }
}
