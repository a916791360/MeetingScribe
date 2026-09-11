import Foundation
import ScreenCaptureKit
import XCTest
@testable import MeetingScribe

private final class UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

final class MixedRecordingSessionConcurrencyTests: XCTestCase {
    func testRecordingStartCallbackMayArriveOffMainActor() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribe-delegate-test-\(UUID().uuidString).mov")
        let session = await MainActor.run {
            MixedRecordingSession(movieURL: outputURL)
        }

        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = outputURL
        configuration.outputFileType = .mov
        let output = SCRecordingOutput(configuration: configuration, delegate: session)

        let callbackCompleted = expectation(description: "ScreenCaptureKit callback completed")
        let sessionBox = UnsafeSendableBox(session)
        let outputBox = UnsafeSendableBox(output)
        let expectationBox = UnsafeSendableBox(callbackCompleted)

        DispatchQueue.global(qos: .userInitiated).async {
            sessionBox.value.recordingOutputDidStartRecording(outputBox.value)
            expectationBox.value.fulfill()
        }

        await fulfillment(of: [callbackCompleted], timeout: 2)
    }
}
