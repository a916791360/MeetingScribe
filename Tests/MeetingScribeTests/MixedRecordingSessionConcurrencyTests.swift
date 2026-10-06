import Foundation
import XCTest
@testable import MeetingScribe

final class MixedRecordingSessionConcurrencyTests: XCTestCase {
    func testCaptureFailureCallbackMayArriveOffMainActorAndReportsOnlyOnce() async throws {
        let failure = expectation(description: "Capture failure delivered on MainActor")
        let temp = FileManager.default.temporaryDirectory
        let session = await MainActor.run {
            let session = MixedRecordingSession(movieURL: temp.appendingPathComponent("delegate-\(UUID()).wav"), localTrackURL: temp.appendingPathComponent("local-\(UUID()).caf"), remoteTrackURL: temp.appendingPathComponent("remote-\(UUID()).caf"))
            session.onFailure = { _ in MainActor.preconditionIsolated(); failure.fulfill() }
            return session
        }
        await Task.detached {
            session.receiveCaptureFailure(PipelineError.failedToStopCapture)
            session.receiveCaptureFailure(PipelineError.failedToStopCapture)
        }.value
        await fulfillment(of: [failure], timeout: 2)
    }
}
