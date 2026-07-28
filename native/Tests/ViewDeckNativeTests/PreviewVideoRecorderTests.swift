import AVFoundation
import XCTest
@testable import ViewDeckCore

final class PreviewVideoRecorderTests: XCTestCase {
    func testFramePacingSchedulesTheNextFrameWhenCaptureIsOnTime() {
        XCTAssertEqual(
            LiveVideoFramePacing.nextFrameNumber(
                after: 0,
                elapsed: 0.01,
                framesPerSecond: 30
            ),
            1
        )
    }

    func testFramePacingSkipsMissedFramesInsteadOfCatchingUp() {
        XCTAssertEqual(
            LiveVideoFramePacing.nextFrameNumber(
                after: 0,
                elapsed: 0.2,
                framesPerSecond: 30
            ),
            6
        )
    }

    func testFramePacingNeverMovesBackward() {
        XCTAssertEqual(
            LiveVideoFramePacing.nextFrameNumber(
                after: 12,
                elapsed: 0.1,
                framesPerSecond: 30
            ),
            13
        )
    }

    func testPresentationTimeUsesTheRequestedFrameRate() {
        let time = LiveVideoFramePacing.presentationTime(
            frameNumber: 45,
            framesPerSecond: 30
        )

        XCTAssertEqual(time.seconds, 1.5, accuracy: 0.000_001)
    }
}
