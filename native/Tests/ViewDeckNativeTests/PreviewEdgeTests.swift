import AppKit
import WebKit
import XCTest
@testable import ViewDeckCore

final class PreviewEdgeTests: XCTestCase {
    func testMainWindowScrollablePreviewPaintsBothEdgesAfterResize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("index.html")
        try """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:white}body{width:100vw;height:200vh}.edge{position:fixed;background:#00ff00}
        #right{right:0;top:0;width:3px;height:100vh}#bottom{bottom:0;left:0;height:3px;width:100vw}</style>
        <div class="edge" id="right"></div><div class="edge" id="bottom"></div>
        """.write(to: fixture, atomically: true, encoding: .utf8)
        let done = expectation(description: "resized preview preserves CSS viewport edges")
        let measured = expectation(description: "scrolling without scrollbar gutters")
        var retainedController: MainWindowController?
        var retained: (PreviewCanvasView, NSWindow)?
        DispatchQueue.main.async {
            let controller = MainWindowController()
            let window = controller.window!
            func findCanvas(_ view: NSView) -> PreviewCanvasView? {
                if let canvas = view as? PreviewCanvasView { return canvas }
                return view.subviews.compactMap(findCanvas).first
            }
            let canvas = findCanvas(window.contentView!)!
            canvas.preview.profile = BuiltinDevices.all.first { $0.id == "iphone-17-pro-max" }!
            let size = window.frame.size
            window.setFrameOrigin(CLIPreviewWindow.origin(showPreview: false, windowSize: size, screenFrames: NSScreen.screens.map(\.frame), mainVisibleFrame: NSScreen.main?.visibleFrame))
            window.orderFrontRegardless()
            retainedController = controller
            retained = (canvas, window)
            canvas.layoutSubtreeIfNeeded()
            _ = canvas.preview.enableOffscreenRendering()
            canvas.preview.loadLocalFile(fixture)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                window.setContentSize(CGSize(width: 1480, height: 920))
                canvas.layoutSubtreeIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    func findWebView(_ view: NSView) -> WKWebView? {
                        if let web = view as? WKWebView { return web }
                        return view.subviews.compactMap(findWebView).first
                    }
                    findWebView(canvas.preview)?.evaluateJavaScript("""
                    window.scrollTo(0, 50);
                    ({width: innerWidth, height: innerHeight,
                      clientWidth: document.documentElement.clientWidth,
                      clientHeight: document.documentElement.clientHeight,
                      scrollY})
                    """) { value, error in
                        XCTAssertNil(error)
                        let metrics = value as? [String: Any]
                        XCTAssertEqual(metrics?["width"] as? Int, 440)
                        XCTAssertEqual(metrics?["height"] as? Int, 956)
                        XCTAssertEqual(metrics?["clientWidth"] as? Int, 440)
                        XCTAssertEqual(metrics?["clientHeight"] as? Int, 956)
                        XCTAssertEqual(metrics?["scrollY"] as? Int, 50, "Scrolling must stay enabled")
                        measured.fulfill()
                    }
                    canvas.preview.captureVideoFrame(scale: 1) { result in
                        do {
                            let image = try result.get()
                            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                            let bitmap = NSBitmapImageRep(cgImage: cgImage)
                            // Allow compositor resampling of the three-pixel marker at fractional scale.
                            for (x, y) in [(bitmap.pixelsWide - 2, bitmap.pixelsHigh / 2), (bitmap.pixelsWide / 3, bitmap.pixelsHigh - 2)] {
                                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                                XCTAssertLessThan(color.redComponent, 0.4, "Clipped page edge at \(x),\(y)")
                                XCTAssertGreaterThan(color.greenComponent, 0.7, "Unpainted page edge at \(x),\(y)")
                            }
                        } catch { XCTFail("\(error)") }
                        window.orderOut(nil)
                        done.fulfill()
                    }
                }
            }
        }
        wait(for: [done, measured], timeout: 15)
        withExtendedLifetime((retained, retainedController)) {}
    }
}
