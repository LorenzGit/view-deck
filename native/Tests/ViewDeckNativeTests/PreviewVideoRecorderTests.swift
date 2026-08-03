import AVFoundation
import XCTest
@testable import ViewDeckCore

final class PreviewVideoRecorderTests: XCTestCase {
    func testCompositorImagePreservesLogicalSizeAtHighDPR() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 3,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let source = try XCTUnwrap(context.makeImage())
        let image = try XCTUnwrap(PreviewImageEncoding.image(
            from: source,
            pixelsWide: 6,
            pixelsHigh: 9,
            pointSize: CGSize(width: 2, height: 3)
        ))

        XCTAssertEqual(image.size, CGSize(width: 2, height: 3))
        XCTAssertEqual(PreviewImageEncoding.pixelSize(of: image), CGSize(width: 6, height: 9))
    }

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
