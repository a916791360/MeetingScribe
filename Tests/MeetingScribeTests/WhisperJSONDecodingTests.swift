import XCTest
@testable import MeetingScribe

final class WhisperJSONDecodingTests: XCTestCase {
    func testStrictUTF8JSONDecodesNormally() throws {
        let data = Data(Self.validJSON.utf8)

        let transcript = try WhisperRawTranscript.decodeWhisperJSON(data)

        XCTAssertEqual(transcript.transcription.count, 1)
        XCTAssertEqual(transcript.transcription[0].text, "正常中文。")
    }

    func testInvalidUTF8ByteInsideWhisperJSONIsReplacedInsteadOfFailingWholeTranscript() throws {
        var data = Data(Self.validJSON.utf8)
        let marker = Data("常".utf8)
        guard let range = data.range(of: marker) else {
            XCTFail("测试夹具应包含中文文本")
            return
        }
        // `0xFC` 是这次真机失败里见到的坏字节形态之一：不是合法 UTF-8 起始字节。
        data[range.lowerBound] = 0xFC

        let transcript = try WhisperRawTranscript.decodeWhisperJSON(data)

        XCTAssertEqual(transcript.transcription.count, 1)
        XCTAssertTrue(
            transcript.transcription[0].text.contains("�"),
            "坏字节要被替换为 U+FFFD，不能让整场转写失败"
        )
    }

    func testValidUTF8ButInvalidJSONStillThrows() throws {
        let data = Data("{\"transcription\": [}".utf8)

        XCTAssertThrowsError(try WhisperRawTranscript.decodeWhisperJSON(data))
    }

    private static let validJSON = """
    {
      "transcription": [
        {
          "timestamps": { "from": "00:00:00,000", "to": "00:00:01,000" },
          "offsets": { "from": 0, "to": 1000 },
          "text": "正常中文。",
          "tokens": [
            { "text": "正常", "p": 0.9, "id": 1 },
            { "text": "中文。", "p": 0.8, "id": 2 }
          ]
        }
      ]
    }
    """
}
