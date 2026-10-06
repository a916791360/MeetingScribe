import XCTest
@testable import MeetingScribe

/// P2-2a 两路合并的判据。
///
/// 这一组测试的存在理由：真实双路音频本机造不出来，录音那一半没法自动验证，
/// 但**合并规则**必须被钉住 —— 它一旦把人认错，逐字稿读起来完全自然，永远没人发现。
final class TranscriptMergerTests: XCTestCase {
    private func segment(
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ text: String,
        confidence: Double = 0.9
    ) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, confidence: confidence)
    }

    // MARK: - 基本行为

    func testInterleavedTracksKeepChronologicalOrderAndSpeaker() {
        let local = [
            segment(0, 5, "我们先看一下报价单"),
            segment(20, 25, "那我这边下周给回复")
        ]
        let remote = [
            segment(8, 14, "价格能不能再降一点"),
            segment(16, 19, "交期也要一并确认")
        ]

        let merged = TranscriptMerger.merge(local: local, remote: remote)

        XCTAssertEqual(merged.map(\.text), [
            "我们先看一下报价单",
            "价格能不能再降一点",
            "交期也要一并确认",
            "那我这边下周给回复"
        ])
        XCTAssertEqual(merged.map(\.speaker), [.local, .remote, .remote, .local])
    }

    func testSingleTrackPassesThroughWithItsOwnSpeaker() {
        let local = [segment(0, 4, "只有我在说话")]

        let merged = TranscriptMerger.merge(local: local, remote: [])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.speaker, .local)
        XCTAssertEqual(merged.first?.text, "只有我在说话")
    }

    func testRemoteOnlyPassesThroughWithRemoteSpeaker() {
        let remote = [segment(3, 7, "只有对方在说话")]

        let merged = TranscriptMerger.merge(local: [], remote: remote)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.speaker, .remote)
    }

    func testBothEmptyReturnsEmpty() {
        XCTAssertTrue(TranscriptMerger.merge(local: [], remote: []).isEmpty)
    }

    func testBlankSegmentsAreDropped() {
        let local = [segment(0, 4, "   "), segment(5, 9, "\n")]

        XCTAssertTrue(TranscriptMerger.merge(local: local, remote: []).isEmpty)
    }

    // MARK: - 串音（外放时麦克风把对方的声音一起收进来）

    func testCrosstalkDuplicateKeepsTheHigherConfidenceCopy() {
        // 同一句话：系统声那一路听得清楚，麦克风那一路是隔空收进来的。
        let remote = [segment(10, 16, "这个方案我们下周给答复", confidence: 0.92)]
        let local = [segment(10.5, 15.8, "这个方案我们下周给答复", confidence: 0.55)]

        let merged = TranscriptMerger.merge(local: local, remote: remote)

        XCTAssertEqual(merged.count, 1, "串音重复必须收敛成一条，否则逐字稿整段重复")
        XCTAssertEqual(merged.first?.speaker, .remote, "留下的应该是听得更清楚的那一路")
        XCTAssertEqual(merged.first?.confidence, 0.92)
    }

    func testCrosstalkWithPunctuationAndSpacingDifferencesStillDeduplicates() {
        let local = [segment(0, 5, "这个方案我们 下周给答复。", confidence: 0.5)]
        let remote = [segment(0, 4.8, "这个方案我们下周给答复", confidence: 0.8)]

        let merged = TranscriptMerger.merge(local: local, remote: remote)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.speaker, .remote)
    }

    func testNearIdenticalTranscriptionsArePreservedWhenMeaningIsUncertain() {
        // 略有出入时无法可靠判断含义相同，保守保留两路内容。
        let local = [segment(0, 5, "这个方案我们下周给答复", confidence: 0.5)]
        let remote = [segment(0, 5, "这个方案我们下周给答复吧", confidence: 0.8)]

        let merged = TranscriptMerger.merge(local: local, remote: remote)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.last?.text, "这个方案我们下周给答复吧")
    }

    func testTinyOverlapIsNotTreatedAsCrosstalk() {
        // 只有 0.5 秒搭边，占较短那段的比例远低于线 —— 两句不同的话都得留下。
        let local = [segment(0, 10, "我先把背景说一下")]
        let remote = [segment(9.5, 14, "那我们直接进入第二个议题")]

        let merged = TranscriptMerger.merge(local: local, remote: remote)

        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - 真·同时说话（必须两条都留）

    func testOverlappingSpeechWithDifferentTextKeepsBothSides() {
        let local = [segment(10, 16, "我同意这个时间点")]
        let remote = [segment(11, 17, "但是预算还要再谈")]

        let merged = TranscriptMerger.merge(local: local, remote: remote)

        XCTAssertEqual(merged.map(\.speaker), [.local, .remote])
        XCTAssertEqual(merged.map(\.text), ["我同意这个时间点", "但是预算还要再谈"])
    }

    func testVeryShortSegmentsOnlyDeduplicateWhenExactlyEqual() {
        // "嗯" 和 "嗯嗯" 不算同一句：短词走相似度会白丢一次发言。
        let local = [segment(0, 1, "嗯嗯")]
        let remote = [segment(0, 1, "嗯")]

        let merged = TranscriptMerger.merge(local: local, remote: remote)

        XCTAssertEqual(merged.count, 2)
    }

    func testSameSpeakerOverlapIsLeftToTheSingleTrackCleaner() {
        // 同一路内部的重复不归这里管（那是 whisper 在长静音上自重复的老问题，
        // 由单路分块拼接 + TranscriptCleaner 处理）。这里动了就会两边打架。
        let local = [
            segment(0, 10, "重复的一句"),
            segment(5, 12, "重复的一句")
        ]

        let merged = TranscriptMerger.merge(local: local, remote: [])

        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.allSatisfy { $0.speaker == .local })
    }

    // MARK: - 确定性

    func testSameTimestampIsResolvedDeterministically() {
        // 两路都从 0 开始且文本不同：必须给一个确定顺序，不能"看哪条先到"。
        let local = [segment(0, 4, "一")]
        let remote = [segment(0, 4, "二")]

        let first = TranscriptMerger.merge(local: local, remote: remote)
        let second = TranscriptMerger.merge(local: local, remote: remote)

        XCTAssertEqual(first.map(\.speaker), [.local, .remote])
        XCTAssertEqual(first.map(\.text), second.map(\.text))
        XCTAssertEqual(first.map(\.speaker), second.map(\.speaker))
    }

    func testInputSpeakerIsOverwrittenByTrackOrigin() {
        // 上游数据说了算不算：说话人由**音轨来源**决定，不由传进来的值决定。
        var mislabeled = segment(0, 4, "对方说的话")
        mislabeled.speaker = .remote

        let merged = TranscriptMerger.merge(local: [mislabeled], remote: [])

        XCTAssertEqual(merged.first?.speaker, .local)
    }

    func testMergeIsIdempotentOnItsOwnOutputShape() {
        // 合并结果按时间单调，且每段都有说话人 —— 上层（分块拼接、清洗）依赖这两条。
        let merged = TranscriptMerger.merge(
            local: [segment(0, 5, "甲"), segment(30, 35, "丙")],
            remote: [segment(10, 15, "乙")]
        )

        XCTAssertEqual(merged.map(\.start), merged.map(\.start).sorted())
        XCTAssertTrue(merged.allSatisfy { $0.speaker != nil })
    }

    // MARK: - 静音通道判定

    func testHasSpeechIgnoresBlankSegments() {
        XCTAssertFalse(TranscriptMerger.hasSpeech([]))
        XCTAssertFalse(TranscriptMerger.hasSpeech([segment(0, 4, "   ")]))
        XCTAssertTrue(TranscriptMerger.hasSpeech([segment(0, 4, "有内容")]))
    }

    // MARK: - 归一化（与单路合并共用同一份实现）

    func testNormalizedStripsSpacingAndTrailingPunctuation() {
        XCTAssertEqual(TranscriptMerger.normalized("这个方案 我们\n下周给答复。"), "这个方案我们下周给答复")
    }
}
