import Foundation
import XCTest

@testable import MeetingScribe

/// 守住逐字稿后处理的三条线：
/// ① **复读要折叠**（实测 10.4% 的段是复读，最长一串重复 86 次）；
/// ② **碎段要并成句**（段均 15 字 → 句子级）；
/// ③ **但不能把内容洗没了** —— 计划给的硬指标是总字数保留 ≥95%。
final class TranscriptCleanerTests: XCTestCase {

    private func segment(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval? = nil,
        confidence: Double = 0.8
    ) -> TranscriptSegment {
        TranscriptSegment(
            start: start,
            end: end ?? (start + 2),
            text: text,
            confidence: confidence
        )
    }

    private func totalChars(_ segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { $0 + $1.text.count }
    }

    // MARK: - 复读折叠

    func testCollapsesInnerImmediateRepeats() {
        let input = [segment("这个这个这个方案我们再确认一下", start: 0)]
        let output = TranscriptCleaner.clean(input)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].text, "这个方案我们再确认一下")
    }

    func testDoesNotCollapseNaturalDoubleWords() {
        // 「看看」「慢慢」是正常中文，重复 2 次不该被动。
        let input = [segment("我们先看看再说", start: 0), segment("慢慢来不用急", start: 3)]
        let output = TranscriptCleaner.clean(input)
        XCTAssertEqual(output.map(\.text).joined(), "我们先看看再说慢慢来不用急")
    }

    func testDoesNotEatDigitsInsideNumbers() {
        // 1000 里有三个连着的 0 —— 重复单元里没有汉字，不能折叠。
        let input = [segment("预算是1000万", start: 0)]
        let output = TranscriptCleaner.clean(input)
        XCTAssertEqual(output[0].text, "预算是1000万")
    }

    func testCollapsesLongRunOfIdenticalSegments() {
        // whisper 在长静音上会进入自重复循环：同一句连着吐几十次。
        var input = [segment("感谢大家观看本次会议", start: 0, end: 2)]
        for index in 1..<86 {
            input.append(segment("感谢大家观看本次会议", start: Double(index) * 2, end: Double(index) * 2 + 2))
        }
        let output = TranscriptCleaner.clean(input)
        XCTAssertEqual(output.count, 1, "86 次重复应折叠成 1 段")
        XCTAssertEqual(output[0].text, "感谢大家观看本次会议")
        XCTAssertEqual(output[0].start, 0)
        XCTAssertEqual(output[0].end, 172, "折叠后时间范围要覆盖到最后一次")
    }

    func testKeepsShortRepeatedInterjections() {
        // 会上连着说三个「对」是真在说话，不是幻觉循环 —— 会被并成一句，
        // 但三个字要原样留着（段内折叠有"总跨度 ≥6 字"的门槛挡着）。
        let input = [
            segment("对", start: 0),
            segment("对", start: 1),
            segment("对", start: 2)
        ]
        let output = TranscriptCleaner.clean(input)
        XCTAssertEqual(output.count, 1, "碎段并成一句")
        XCTAssertEqual(output[0].text, "对对对", "短叠词不能被当成卡带削掉")
    }

    // MARK: - 按句合并

    func testMergesFragmentsIntoSentenceLevelSegments() {
        let input = [
            segment("我们今天主要讨论", start: 0),
            segment("三个议题第一个是", start: 2),
            segment("价格体系怎么调整。", start: 4),
            segment("第二个议题是渠道。", start: 6)
        ]
        let output = TranscriptCleaner.clean(input)
        XCTAssertEqual(output.count, 2, "遇到句号就断开")
        XCTAssertEqual(output[0].text, "我们今天主要讨论三个议题第一个是价格体系怎么调整。")
        XCTAssertEqual(output[0].start, 0)
        XCTAssertEqual(output[0].end, 6)
        XCTAssertEqual(output[1].text, "第二个议题是渠道。")
    }

    func testStopsMergingAtCharacterLimit() {
        // 一整段没有任何句末标点 → 只能靠长度上限断开。
        // 每段文本都不一样，避免被"相邻段复读"那条规则先折掉。
        let input = (0..<40).map { index in
            segment("第\(index)条内容还需要再确认一次", start: Double(index) * 2)
        }
        let output = TranscriptCleaner.clean(input)
        XCTAssertGreaterThan(output.count, 1, "超过上限必须断开")
        XCTAssertTrue(
            output.allSatisfy { $0.text.count <= 160 + 20 },
            "每段都该在上限附近，不能并成一整段"
        )
        // 内容不能丢：并句只搬位置，不改字。
        XCTAssertEqual(totalChars(output), totalChars(input))
    }

    // MARK: - 术语替换

    func testAppliesTerminologyTable() {
        let input = [segment("这次课考反馈说败网时间要改", start: 0)]
        let output = TranscriptCleaner.clean(input)
        XCTAssertEqual(output[0].text, "这次客户反馈说拜访时间要改")
    }

    // MARK: - 丢低置信

    func testDropsShortLowConfidenceJunk() {
        let input = [
            segment("呃", start: 0, confidence: 0.05),
            segment("……", start: 1, confidence: 0.05),
            segment("我们把方案定下来。", start: 2, confidence: 0.9)
        ]
        let output = TranscriptCleaner.clean(input)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].text, "我们把方案定下来。")
    }

    func testKeepsShortTextWhenConfidenceIsFine() {
        let input = [segment("对，是的。", start: 0, confidence: 0.9)]
        let output = TranscriptCleaner.clean(input)
        XCTAssertEqual(output.count, 1, "短不等于垃圾，置信度正常就保留")
    }

    // MARK: - 整体约束

    func testKeepsHeavyMajorityOfUniqueContent() {
        // 按真实数据的形状造：段均十几字、无标点的碎句，句尾才有一个句号，
        // 外加尾巴上一段 whisper 的自重复循环。
        var input: [TranscriptSegment] = []
        var time: TimeInterval = 0
        for sentence in 0..<200 {
            for part in 0..<4 {
                let tail = part == 3 ? "。" : ""
                input.append(segment("第\(sentence)段的第\(part)个小点\(tail)", start: time))
                time += 2
            }
        }
        for _ in 0..<86 {
            input.append(segment("感谢大家观看本次会议。", start: time))
            time += 2
        }

        let output = TranscriptCleaner.clean(input)
        let deduplicated = TranscriptCleaner.removingRepeats(input)

        XCTAssertLessThanOrEqual(
            Double(output.count) / Double(input.count), 0.25,
            "段数应当明显下降（计划验收：≤25%）"
        )
        // 「删过头」的判据必须拿**去重之后**的字数当分母：复读本身占一成，
        // 那是按设计就该丢的，拿原文当分母会把"正确地删掉复读"误判成"删过头"。
        XCTAssertGreaterThanOrEqual(
            Double(totalChars(output)) / Double(totalChars(deduplicated)), 0.95,
            "去重之后的内容不能继续丢"
        )
        XCTAssertLessThan(
            Double(totalChars(deduplicated)) / Double(totalChars(input)), 0.95,
            "复读那部分就是要丢的，不去重说明折叠没起作用"
        )
    }

    func testIsIdempotentSoStoredTranscriptsDoNotShrinkAgain() {
        // 清洗结果会写回会话，而评测集是从会话导出的 —— 再洗一遍不能继续缩水。
        var input: [TranscriptSegment] = []
        var time: TimeInterval = 0
        for _ in 0..<20 {
            input.append(segment("这一段需要确认一下。", start: time))
            time += 2
            input.append(segment("好的好的好的我记下了", start: time))
            time += 2
        }
        let once = TranscriptCleaner.clean(input)
        let twice = TranscriptCleaner.clean(once)
        XCTAssertEqual(once.map(\.text), twice.map(\.text))
        XCTAssertEqual(once.count, twice.count)
    }

    func testHandlesEmptyInput() {
        XCTAssertTrue(TranscriptCleaner.clean([]).isEmpty)
    }
}
