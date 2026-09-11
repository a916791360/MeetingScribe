import Foundation
import XCTest
@testable import MeetingScribe

final class SummaryModelDiscoveryTests: XCTestCase {
    func testModelListPayloadSupportsOpenAIObjectsAndStringEntries() throws {
        let objectPayload = Data("""
        {"data":[{"id":"gpt-6-astra","name":"Astra"},{"id":" deepseek-v4-pro "},{"name":"fallback-name"},{"id":"gpt-6-astra"}]}
        """.utf8)

        let stringPayload = Data("""
        {"models":["qwen-plus",{"id":"moonshot-v1-8k"}," qwen-plus "]}
        """.utf8)

        XCTAssertEqual(
            try SummaryModelDiscovery.parse(objectPayload),
            ["deepseek-v4-pro", "fallback-name", "gpt-6-astra"]
        )
        XCTAssertEqual(
            try SummaryModelDiscovery.parse(stringPayload),
            ["moonshot-v1-8k", "qwen-plus"]
        )
    }

    func testModelListPayloadSupportsCommonNestedModelArrays() throws {
        let payload = Data("""
        {"result":{"models":[{"model":"provider/model-a"},{"name":"model-b"}]}}
        """.utf8)

        XCTAssertEqual(
            try SummaryModelDiscovery.parse(payload),
            ["model-b", "provider/model-a"]
        )
    }

    func testEmptyModelListIsDifferentFromMalformedPayload() throws {
        let emptyPayload = Data("{\"data\":[]}".utf8)
        XCTAssertEqual(try SummaryModelDiscovery.parse(emptyPayload), [])

        let malformedPayload = Data("{\"message\":\"not a model list\"}".utf8)
        XCTAssertThrowsError(try SummaryModelDiscovery.parse(malformedPayload))
    }

    func testEndpointNormalizationKeepsProviderBasePath() throws {
        XCTAssertEqual(
            try SummaryModelEndpoint.chatCompletionsURL(from: "https://example.com/v1/").absoluteString,
            "https://example.com/v1/chat/completions"
        )
        XCTAssertEqual(
            SummaryModelEndpoint.modelsURL(
                from: try XCTUnwrap(URL(string: "https://example.com/v1/chat/completions"))
            )?.absoluteString,
            "https://example.com/v1/models"
        )
    }

    func testDiscoveryNeverPicksTheFirstModelForTheUser() {
        XCTAssertEqual(
            SummaryModelDiscovery.selectionAfterDiscovery(
                current: "model-b",
                available: ["model-a", "model-b"]
            ),
            "model-b"
        )
        XCTAssertNil(
            SummaryModelDiscovery.selectionAfterDiscovery(
                current: "old-model",
                available: ["model-a", "model-b"]
            )
        )
        XCTAssertNil(
            SummaryModelDiscovery.selectionAfterDiscovery(
                current: "",
                available: ["model-a", "model-b"]
            )
        )
    }

    func testCurrentManualModelTakesPriorityOverPendingModel() {
        XCTAssertEqual(
            SummaryModelDiscovery.selectionCandidate(
                current: "new-manual-model",
                pending: "old-model"
            ),
            "new-manual-model"
        )
        XCTAssertEqual(
            SummaryModelDiscovery.selectionCandidate(
                current: "  ",
                pending: "old-model"
            ),
            "old-model"
        )
    }
}
