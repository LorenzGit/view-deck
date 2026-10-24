import AppKit
import AVFoundation
import WebKit
import XCTest
@testable import ViewDeckCore

final class PreviewVideoRecorderTests: XCTestCase {
    func testHighQualityEncodingPreservesDetailAtDeviceResolution() {
        let settings = LivePreviewVideoQuality.high.compressionProperties(
            width: 1320, height: 2868, framesPerSecond: 30
        )
        XCTAssertGreaterThan(settings[AVVideoAverageBitRateKey] as? Int ?? 0, 30_000_000)
        XCTAssertEqual(settings[AVVideoProfileLevelKey] as? String, AVVideoProfileLevelH264HighAutoLevel)
        XCTAssertEqual(settings[AVVideoExpectedSourceFrameRateKey] as? Int, 30)
    }

    @MainActor
    func testUIRecordingRestoresDeviceFrameAfterCaptureFailure() async throws {
        _ = NSApplication.shared
        for originallyFramed in [true, false] {
            let preview = DevicePreviewView(profile: BuiltinDevices.all[0])
            preview.showsDeviceFrame = originallyFramed
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            let recorder = LivePreviewVideoRecorder.uiRecording(outputURL: output, preview: preview)
            let finished = expectation(description: "recording failure restores frame")
            recorder.record(preview: preview) { result in
                if case .success = result { XCTFail("An unattached preview cannot be captured") }
                XCTAssertEqual(preview.showsDeviceFrame, originallyFramed)
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 5)
            withExtendedLifetime(recorder) {}
        }
    }

    @MainActor
    func testUIRecordingExportsFramelessDeviceResolutionMP4() async throws {
        _ = NSApplication.shared
        let artifactPath = ProcessInfo.processInfo.environment["VIEWDECK_VIDEO_TEST_ARTIFACTS"]
        let directory = artifactPath.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if artifactPath == nil { try? FileManager.default.removeItem(at: directory) } }
        let profile = try XCTUnwrap(BuiltinDevices.all.first { $0.id == "iphone-17-pro-max" })
        let canvas = PreviewCanvasView(profile: profile)
        let preview = canvas.preview
        let window = CLIPreviewWindow.make(contentView: canvas, size: CGSize(width: 800, height: 850), showPreview: false)
        defer { window.close() }
        canvas.layoutSubtreeIfNeeded()
        XCTAssertTrue(preview.enableOffscreenRendering())
        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap { webView(in: $0) }.first
        }
        let web = try XCTUnwrap(webView(in: preview))
        let navigation = VideoFixtureNavigation()
        web.navigationDelegate = navigation
        web.loadHTMLString("""
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>html,body{margin:0;background:#00ff00;color:#000;font:16px sans-serif}
            main{position:absolute;top:45%;width:100%;text-align:center}</style>
            <main>Sharp text in a frameless video<br>ViewDeck recording check</main>
            """, baseURL: nil)
        await fulfillment(of: [navigation.loaded], timeout: 10)
        try await Task.sleep(for: .milliseconds(300))
        let output = directory.appendingPathComponent("ui-recording.mp4")
        let recorder = LivePreviewVideoRecorder.uiRecording(outputURL: output, preview: preview)
        let finished = expectation(description: "UI MP4 saved")
        recorder.record(preview: preview) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            XCTAssertTrue(preview.showsDeviceFrame, "Restore the interactive preview after saving")
            finished.fulfill()
        }
        XCTAssertFalse(preview.showsDeviceFrame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { recorder.stop() }
        await fulfillment(of: [finished], timeout: 15)

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1320, height: 2868))
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.3)
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try await generator.image(at: .zero).image
        let bitmap = NSBitmapImageRep(cgImage: image)
        let sensor = SensorGeometry.frame(sensor: profile.sensor,
                                         viewportFrame: CGRect(origin: .zero, size: preview.logicalViewportSize),
                                         landscape: false)
        for point in [CGPoint(x: 3, y: 3), CGPoint(x: 1316, y: 3),
                      CGPoint(x: 3, y: 2864), CGPoint(x: 1316, y: 2864),
                      CGPoint(x: sensor.midX * 3, y: sensor.midY * 3),
                      CGPoint(x: 660, y: 2840)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(color.greenComponent, 0.8, "No skin, corner mask, sensor, or home indicator at \(point)")
            XCTAssertLessThan(color.redComponent, 0.2)
        }
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("first-frame.png"))
        withExtendedLifetime((recorder, navigation)) {}
    }

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

@MainActor
private final class VideoFixtureNavigation: NSObject, WKNavigationDelegate {
    let loaded = XCTestExpectation(description: "video fixture loaded")

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }
}
