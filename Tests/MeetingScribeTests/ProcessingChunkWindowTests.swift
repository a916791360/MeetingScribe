import XCTest
@testable import MeetingScribe

/// 分块窗口的**迁移不变式**。
///
/// `chunkWindow` / `ownedSegments` 原来内联在 `MeetingStore.process` 的循环里。
/// 双声道（P2-2a）要复用同一份算法，才把它们抽了出来 —— 而**搬迁是静默改变**
/// （不崩、不报错，只是分块边界悄悄挪了几秒，转写结果看着也「正常」）。
///
/// 所以这里把搬迁**之前**的行为值逐个钉住：值对不上，就说明行为被改过。
final class ProcessingChunkWindowTests: XCTestCase {
    /// 这些常量是 `MeetingStore` 里的私有值，这里是它们的事实写照。
    private let chunkDuration: TimeInterval = 10 * 60
    private let overlap: TimeInterval = 2

    // MARK: - 块数

    @MainActor
    func testChunkCountMatchesTheInlineFormula() {
        XCTAssertEqual(MeetingStore.chunkCount(for: 0), 1, "再短的音频也得有一块")
        XCTAssertEqual(MeetingStore.chunkCount(for: 1), 1)
        XCTAssertEqual(MeetingStore.chunkCount(for: chunkDuration), 1, "正好一整块还是一块")
        XCTAssertEqual(MeetingStore.chunkCount(for: chunkDuration + 0.5), 2)
        XCTAssertEqual(MeetingStore.chunkCount(for: 1500), 3, "25 分钟 → 3 块")
        XCTAssertEqual(MeetingStore.chunkCount(for: 2682), 5, "44.7 分钟的会 → 5 块")
    }

    // MARK: - 窗口取值（搬迁前的具体数字）

    @MainActor
    func testWindowsForTwentyFiveMinutes() {
        let first = MeetingStore.chunkWindow(index: 0, duration: 1500)
        XCTAssertEqual(first.coreStart, 0)
        XCTAssertEqual(first.coreEnd, 600)
        XCTAssertEqual(first.start, 0, "第一块前面没有东西可重叠")
        XCTAssertEqual(first.end, 600 + overlap, "后面多给 2 秒重叠")
        XCTAssertEqual(first.length, 602, accuracy: 0.0001)

        let second = MeetingStore.chunkWindow(index: 1, duration: 1500)
        XCTAssertEqual(second.coreStart, 600)
        XCTAssertEqual(second.coreEnd, 1200)
        XCTAssertEqual(second.start, 600 - overlap, "前面多给 2 秒重叠")
        XCTAssertEqual(second.end, 1200 + overlap)
        XCTAssertEqual(second.length, 604, accuracy: 0.0001)

        let last = MeetingStore.chunkWindow(index: 2, duration: 1500)
        XCTAssertEqual(last.coreStart, 1200)
        XCTAssertEqual(last.coreEnd, 1500)
        XCTAssertEqual(last.start, 1200 - overlap)
        XCTAssertEqual(last.end, 1500, "最后一块后面没有东西可重叠")
        XCTAssertEqual(last.length, 302, accuracy: 0.0001)
    }

    @MainActor
    func testSingleChunkExactlyOneWindowHasNoOverlapAtAll() {
        let window = MeetingStore.chunkWindow(index: 0, duration: 600)

        XCTAssertEqual(window.coreStart, 0)
        XCTAssertEqual(window.coreEnd, 600)
        XCTAssertEqual(window.start, 0)
        XCTAssertEqual(window.end, 600)
    }

    @MainActor
    func testVeryShortAudioStillGetsAUsableLength() {
        // 时长 0 会让 whisper 把 `-d 0` 当成"整段"，也曾经让除法变成 0。
        let window = MeetingStore.chunkWindow(index: 0, duration: 0.5)

        XCTAssertGreaterThanOrEqual(window.length, 0.1)
    }

    // MARK: - 归属

    @MainActor
    func testFirstChunkOwnsEverythingBeforeItsCoreEnd() {
        let window = MeetingStore.chunkWindow(index: 0, duration: 1500)
        let segments = [
            segment(0, 3, "开头"),
            segment(599, 601, "跨过核心终点"),
            segment(600, 603, "核心终点之后"),
            segment(601.5, 604, "更后面")
        ]

        XCTAssertEqual(
            MeetingStore.ownedSegments(segments, index: 0, in: window).map(\.text),
            ["开头", "跨过核心终点"]
        )
    }

    @MainActor
    func testLaterChunksOwnTheirCoreRangeAndTheOverlapBeforeItBelongsToThePreviousChunk() {
        let window = MeetingStore.chunkWindow(index: 1, duration: 1500)
        let segments = [
            segment(590, 593, "前一块的尾巴"),
            segment(598, 601, "重叠区的段（归前一块）"),
            segment(600, 603, "本块第一句"),
            segment(1199, 1201, "本块最后一句"),
            segment(1200, 1203, "下一块第一句")
        ]

        XCTAssertEqual(
            MeetingStore.ownedSegments(segments, index: 1, in: window).map(\.text),
            ["本块第一句", "本块最后一句"]
        )
    }

    @MainActor
    func testEverySegmentBelongsToExactlyOneChunkOnAFullTimeline() {
        // 两路合并依赖这条性质：任何一段都必须**恰好**被一块认领，
        // 多一块认领会重复、少一块认领会丢句子。
        let duration: TimeInterval = 1500
        var owners: [String: [Int]] = [:]
        let segments = (0..<40).map { index in
            segment(Double(index) * 37, Double(index) * 37 + 5, "第 \(index) 句")
        }

        for chunk in 0..<MeetingStore.chunkCount(for: duration) {
            let window = MeetingStore.chunkWindow(index: chunk, duration: duration)
            for owned in MeetingStore.ownedSegments(segments, index: chunk, in: window) {
                owners[owned.text, default: []].append(chunk)
            }
        }

        XCTAssertFalse(owners.isEmpty)
        XCTAssertTrue(
            owners.values.allSatisfy { $0.count == 1 },
            "有段被两块同时认领或一段都没被认领：\(owners.filter { $0.value.count != 1 })"
        )
    }

    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, confidence: 0.9)
    }
}
