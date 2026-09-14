import XCTest
@testable import MeetingScribe

/// `speaker` 字段的存盘契约 + 送进整理模型的行格式。
///
/// 这一组测试盯的是本项目栽过的那类坑：**新字段让老数据读不出来**、
/// **同一个判据有两份实现**（正文一处、分章一处）。
final class TranscriptSpeakerTests: XCTestCase {
    private let legacySessionJSON = """
    {"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","start":0,"end":3.5,\
    "text":"老会话的一段","confidence":0.7}
    """

    // MARK: - 存盘契约

    func testLegacySegmentWithoutSpeakerStillDecodes() throws {
        // 升级前存下来的段里没有 `speaker` 这个键。它必须照旧能解出来 ——
        // 合成 `Decodable` **不理会属性默认值**，一旦写成非 Optional，所有老会话直接读不出。
        let segment = try JSONDecoder().decode(
            TranscriptSegment.self,
            from: Data(legacySessionJSON.utf8)
        )

        XCTAssertNil(segment.speaker)
        XCTAssertNil(segment.manuallyEditedAt)
        XCTAssertEqual(segment.text, "老会话的一段")
    }

    func testNilSpeakerIsWrittenAsAnAbsentKeyNotNull() throws {
        // 键"在不在"和我们怎么说这个字段是有区别的：写一个 `"speaker": null` 进去，
        // 老版本 App（或任何按"键在不在"判断的分析脚本）会以为这里是"算过但没算出来"。
        // 指标脚本已经吃过一次这个亏，别再来第二次。
        let segment = TranscriptSegment(start: 0, end: 1, text: "一段", confidence: 0.5)

        let data = try JSONEncoder().encode(segment)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("\"speaker\""), "speaker 为 nil 时必须省略键：\(json)")
        XCTAssertFalse(json.contains("\"manuallyEditedAt\""))
    }

    func testSpeakerRoundTrips() throws {
        var segment = TranscriptSegment(start: 0, end: 1, text: "对方说的", confidence: 0.5)
        segment.speaker = .remote

        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)

        XCTAssertEqual(decoded.speaker, .remote)
    }

    func testRawValuesArePinned() {
        // 存盘用的是 rawValue。改名字 = 已存盘的说话人全部退回 nil，
        // 而且**不会报错**（只是界面上标签不见了）。所以把字面量钉在这里。
        XCTAssertEqual(TranscriptSpeaker.local.rawValue, "local")
        XCTAssertEqual(TranscriptSpeaker.remote.rawValue, "remote")
    }

    func testDisplayNamesAreTheOnesTheUIAndPromptPromise() {
        XCTAssertEqual(TranscriptSpeaker.local.displayName, "我方")
        XCTAssertEqual(TranscriptSpeaker.remote.displayName, "对方")
    }

    // MARK: - 送进整理模型的行格式

    func testMaterialLineCarriesSpeakerPrefix() {
        var segment = TranscriptSegment(start: 12.34, end: 15, text: "这句话是对方说的", confidence: 0.9)
        segment.speaker = .remote

        XCTAssertEqual(segment.materialLine, "[12.3] [对方] 这句话是对方说的")
    }

    func testMaterialLineWithoutSpeakerHasNoPlaceholder() {
        // 没有说话人时**整段前缀都不出现**。写 `[不明]` 之类会让模型去解释一个假信息，
        // 也可能被它写进纪要里。
        let segment = TranscriptSegment(start: 5, end: 8, text: "这一段没分出来", confidence: 0.9)

        XCTAssertEqual(segment.materialLine, "[5.0] 这一段没分出来")
    }

    func testMaterialLineUsesLocalNameForLocalSpeaker() {
        var segment = TranscriptSegment(start: 0, end: 3, text: "这句话是我说的", confidence: 0.9)
        segment.speaker = .local

        XCTAssertEqual(segment.materialLine, "[0.0] [我方] 这句话是我说的")
    }
}
