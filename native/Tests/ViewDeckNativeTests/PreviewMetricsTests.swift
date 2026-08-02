import AppKit
import WebKit
import XCTest
@testable import ViewDeckCore

private func firstWebView(in view: NSView) -> WKWebView? {
    if let webView = view as? WKWebView { return webView }
    for subview in view.subviews {
        if let webView = firstWebView(in: subview) { return webView }
    }
    return nil
}

private func allWebViews(in view: NSView) -> [WKWebView] {
    var result: [WKWebView] = []
    if let webView = view as? WKWebView {
        result.append(webView)
    }
    for subview in view.subviews {
        result.append(contentsOf: allWebViews(in: subview))
    }
    return result
}

private final class PreviewNavigationProbe: DevicePreviewDelegate {
    var starts = 0
    var finishes = 0
    var didFinish: ((String?, URL?) -> Void)?
    var didFail: ((String) -> Void)?

    func previewDidStartLoading() {
        starts += 1
    }

    func previewDidFinishLoading(title: String?, url: URL?) {
        finishes += 1
        didFinish?(title, url)
    }

    func previewDidFail(_ message: String) {
        didFail?(message)
    }
}

final class PreviewMetricsTests: XCTestCase {
    func testHostedPageViewportMatchesIPhoneSafari() {
        let device = BuiltinDevices.all[0]
        XCTAssertEqual(
            PreviewMetrics.contentSize(device: device, landscape: false, headerHeight: 0, footerHeight: 0),
            CGSize(width: 440, height: 766)
        )
    }

    func testDirectPageWithSampleHeaderMatchesInnerFrame() {
        let device = BuiltinDevices.all[0]
        XCTAssertEqual(
            PreviewMetrics.contentSize(device: device, landscape: false, headerHeight: 48, footerHeight: 0),
            CGSize(width: 440, height: 718)
        )
    }

    func testLandscapeSideRailsReserveWidthOnlyWhenRotated() {
        let device = BuiltinDevices.all[0]

        XCTAssertEqual(
            PreviewMetrics.contentSize(
                device: device,
                landscape: true,
                headerHeight: 0,
                footerHeight: 0,
                leftWidth: 118,
                rightWidth: 118
            ),
            CGSize(width: 720, height: 316)
        )
        XCTAssertEqual(
            PreviewMetrics.contentSize(
                device: device,
                landscape: false,
                headerHeight: 0,
                footerHeight: 0,
                leftWidth: 118,
                rightWidth: 118
            ),
            CGSize(width: 440, height: 766)
        )
    }

    func testLandscapeSideRailsLeaveAtLeastOnePagePixel() {
        let widths = PreviewMetrics.sideLayerWidths(
            viewportWidth: 320,
            landscape: true,
            leftWidth: 400,
            rightWidth: 400
        )

        XCTAssertEqual(widths.left, 319)
        XCTAssertEqual(widths.right, 0)
    }

    func testSafariBottomChromeOverlapsTheContentSeam() {
        XCTAssertEqual(
            SafariChromeMetrics.bottomFrame(
                viewportSize: CGSize(width: 440, height: 956),
                chromeHeight: SafariChromeMetrics.portraitBottom
            ),
            CGRect(x: 0, y: 874, width: 440, height: 82)
        )
    }

    func testIPhone17ProMaxAppMatchesCapturedViewportAndInsets() throws {
        let device = try XCTUnwrap(BuiltinDevices.all.first { $0.id == "iphone-17-pro-max" })

        XCTAssertEqual(device.viewport, Viewport(width: 440, height: 956, dpr: 3))
        XCTAssertEqual(device.safeArea, EdgeInsets(top: 62, right: 0, bottom: 34, left: 0))
        XCTAssertEqual(device.shell, DeviceShell(top: 10, right: 10, bottom: 10, left: 10, radius: 61))
        XCTAssertEqual(
            PreviewMetrics.contentSize(device: device, landscape: false, headerHeight: 0, footerHeight: 0),
            CGSize(width: 440, height: 956)
        )
        XCTAssertFalse(device.safariChrome)
    }

    func testIPhoneAppHeaderStartsBelowStatusBar() throws {
        let device = try XCTUnwrap(BuiltinDevices.all.first { $0.id == "iphone-17-pro-max" })

        XCTAssertEqual(PreviewMetrics.appStatusBarHeight(device: device, landscape: false), 62)
        XCTAssertEqual(
            PreviewMetrics.headerTopInset(device: device, landscape: false, headerHeight: 48),
            62
        )
        XCTAssertEqual(
            PreviewMetrics.headerReservedHeight(device: device, landscape: false, headerHeight: 48),
            110
        )
        XCTAssertEqual(
            PreviewMetrics.contentSize(device: device, landscape: false, headerHeight: 48, footerHeight: 56),
            CGSize(width: 440, height: 790)
        )
    }

    func testIPhoneAppHeaderReservesPageGeometryWithoutAnotherNativeInset() throws {
        guard #available(macOS 26.0, *) else { return }
        let device = try XCTUnwrap(BuiltinDevices.all.first { $0.id == "iphone-17-pro-max" })
        let preview = DevicePreviewView(profile: device)
        preview.headerHTML = "<!doctype html><header>Toolbar</header>"
        preview.headerHeight = 48
        preview.frame = CGRect(origin: .zero, size: preview.logicalSize)
        preview.layoutSubtreeIfNeeded()

        let webViews = allWebViews(in: preview)
        XCTAssertTrue(webViews.map(\.frame).contains(CGRect(x: 0, y: 62, width: 444, height: 48)))
        let page = try XCTUnwrap(webViews.first { $0.frame.height == 850 })
        XCTAssertEqual(page.frame, CGRect(x: 0, y: 110, width: 444, height: 850))
        XCTAssertEqual(page.obscuredContentInsets.top, 0)
        XCTAssertEqual(page.obscuredContentInsets.bottom, 0)
    }

    func testHeaderMakesAnEmbeddedRuntimeTreatZeroTopInsetAsAuthoritative() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewDeckHeaderRuntime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("index.html")
        try """
        <!doctype html>
        <title>header runtime</title>
        <script>
          window.RundotGameAPI = { isMock: () => true };
          window.headerUsesAuthoritativeInsets = window.RundotGameAPI.isMock() === false;
        </script>
        """.write(to: file, atomically: true, encoding: .utf8)

        let settled = expectation(description: "header runtime settles")
        var retainedPreview: DevicePreviewView?
        var retainedProbe: PreviewNavigationProbe?

        DispatchQueue.main.async {
            let preview = DevicePreviewView(profile: BuiltinDevices.all[1])
            let probe = PreviewNavigationProbe()
            retainedPreview = preview
            retainedProbe = probe
            preview.delegate = probe
            preview.headerHTML = "<!doctype html><header>Toolbar</header>"

            probe.didFinish = { _, url in
                guard url?.standardizedFileURL == file.standardizedFileURL,
                      let webView = firstWebView(in: preview) else { return }
                webView.evaluateJavaScript("window.headerUsesAuthoritativeInsets === true") { value, error in
                    XCTAssertNil(error)
                    XCTAssertEqual(value as? Bool, true)
                    settled.fulfill()
                }
            }
            probe.didFail = { message in
                XCTFail("Preview failed while testing header runtime: \(message)")
                settled.fulfill()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                preview.loadLocalFile(file)
            }
        }

        wait(for: [settled], timeout: 5)
        withExtendedLifetime((retainedPreview, retainedProbe)) {}
    }

    func testHiddenPreviewRendersAndCapturesWebGPU() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("WebGPU ships with WebKit on macOS 26 and newer.")
        }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/webgpu/index.html")
        let device = try XCTUnwrap(BuiltinDevices.all.first { $0.id == "iphone-17-pro-max" })
        let completed = expectation(description: "hidden WebGPU frame renders and captures")
        var retainedPreview: DevicePreviewView?
        var retainedProbe: PreviewNavigationProbe?
        var retainedWindow: NSWindow?

        DispatchQueue.main.async {
            let preview = DevicePreviewView(profile: device)
            let probe = PreviewNavigationProbe()
            let size = preview.logicalSize
            preview.frame = CGRect(origin: .zero, size: size)
            preview.bounds = preview.frame
            preview.autoresizingMask = [.width, .height]
            let window = CLIPreviewWindow.make(
                contentView: preview,
                size: size,
                showPreview: false
            )
            retainedPreview = preview
            retainedProbe = probe
            retainedWindow = window
            preview.delegate = probe

            XCTAssertFalse(CLIPreviewWindow.intersectsDisplay(window))
            guard preview.enableOffscreenRendering() else {
                XCTFail("The host WebKit cannot keep an offscreen preview active.")
                completed.fulfill()
                return
            }

            probe.didFinish = { _, url in
                guard url?.standardizedFileURL == fixture.standardizedFileURL,
                      let webView = firstWebView(in: preview) else { return }
                let verifyCapture = {
                    preview.captureVideoFrame(scale: 1) { result in
                        do {
                            let image = try result.get()
                            guard let cgImage = image.cgImage(
                                forProposedRect: nil,
                                context: nil,
                                hints: nil
                            ) else {
                                XCTFail("The captured WebGPU frame has no pixel data.")
                                completed.fulfill()
                                return
                            }
                            let bitmap = NSBitmapImageRep(cgImage: cgImage)
                            let color = bitmap.colorAt(
                                x: bitmap.pixelsWide / 2,
                                y: bitmap.pixelsHigh / 2
                            )?.usingColorSpace(.deviceRGB)
                            XCTAssertNotNil(color)
                            XCTAssertGreaterThan(color?.greenComponent ?? 0, 0.65)
                            XCTAssertLessThan(color?.redComponent ?? 1, 0.2)
                            XCTAssertLessThan(color?.blueComponent ?? 1, 0.35)
                            completed.fulfill()
                        } catch {
                            XCTFail("Could not capture the WebGPU frame: \(error)")
                            completed.fulfill()
                        }
                    }
                }
                var pollCount = 0
                var poll: (() -> Void)!
                poll = {
                    webView.evaluateJavaScript("""
                    JSON.stringify({
                      status: document.documentElement.dataset.webgpuStatus || '',
                      hidden: document.hidden,
                      frame: Number(document.documentElement.dataset.webgpuFrame || 0)
                    })
                    """) { value, error in
                        XCTAssertNil(error)
                        guard let encoded = value as? String,
                              let data = encoded.data(using: .utf8),
                              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else {
                            XCTFail("The WebGPU fixture returned an invalid state.")
                            completed.fulfill()
                            return
                        }

                        switch state["status"] as? String {
                        case "ready":
                            XCTAssertEqual(state["hidden"] as? Bool, false)
                            let readyFrame = (state["frame"] as? NSNumber)?.intValue ?? 0
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                webView.evaluateJavaScript(
                                    "Number(document.documentElement.dataset.webgpuFrame || 0)"
                                ) { value, error in
                                    XCTAssertNil(error)
                                    XCTAssertGreaterThan(
                                        (value as? NSNumber)?.intValue ?? 0,
                                        readyFrame,
                                        "The hidden WebGPU animation stopped after its first frame."
                                    )
                                    verifyCapture()
                                }
                            }
                        case "failed":
                            XCTFail("The WebGPU fixture failed to initialize.")
                            completed.fulfill()
                        default:
                            pollCount += 1
                            if pollCount >= 200 {
                                XCTFail("The WebGPU fixture did not render in time.")
                                completed.fulfill()
                            } else {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll)
                            }
                        }
                    }
                }
                poll()
            }
            probe.didFail = { message in
                XCTFail("Preview failed while testing WebGPU: \(message)")
                completed.fulfill()
            }
            preview.loadLocalFile(fixture)
        }

        wait(for: [completed], timeout: 10)
        retainedWindow?.orderOut(nil)
        withExtendedLifetime((retainedPreview, retainedProbe, retainedWindow)) {}
    }

    func testPreviewReportsCompletedAndFailedPageResources() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewDeckNetworkActivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = directory.appendingPathComponent("index.html")
        try """
        <!doctype html>
        <title>network activity</title>
        <link rel="stylesheet" href="style.css">
        <script src="app.js" defer></script>
        <img src="image.svg" alt="fixture">
        <img src="missing.png" alt="missing">
        """.write(to: page, atomically: true, encoding: .utf8)
        try "body { color: rgb(1, 2, 3); }".write(
            to: directory.appendingPathComponent("style.css"),
            atomically: true,
            encoding: .utf8
        )
        try "window.networkFixtureLoaded = true;".write(
            to: directory.appendingPathComponent("app.js"),
            atomically: true,
            encoding: .utf8
        )
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="2" height="2">
          <rect width="2" height="2" fill="red"/>
        </svg>
        """.write(
            to: directory.appendingPathComponent("image.svg"),
            atomically: true,
            encoding: .utf8
        )

        let captured = expectation(description: "resource activity captured")
        var retainedPreview: DevicePreviewView?
        var retainedProbe: PreviewNavigationProbe?
        DispatchQueue.main.async {
            let preview = DevicePreviewView(profile: BuiltinDevices.all[1])
            let probe = PreviewNavigationProbe()
            retainedPreview = preview
            retainedProbe = probe
            preview.delegate = probe
            probe.didFinish = { _, url in
                guard url?.standardizedFileURL == page.standardizedFileURL else { return }
                preview.captureNetworkActivity { result in
                    switch result {
                    case .failure(let error):
                        XCTFail("Could not capture resource activity: \(error)")
                    case .success(let snapshot):
                        let resourcesByName = Dictionary(
                            snapshot.resources.map { (URL(string: $0.url)?.lastPathComponent ?? "", $0) },
                            uniquingKeysWith: { first, _ in first }
                        )
                        XCTAssertEqual(resourcesByName["index.html"]?.status, .complete)
                        XCTAssertEqual(resourcesByName["style.css"]?.status, .complete)
                        XCTAssertEqual(resourcesByName["app.js"]?.status, .complete)
                        XCTAssertEqual(resourcesByName["image.svg"]?.status, .complete)
                        XCTAssertEqual(resourcesByName["missing.png"]?.status, .failed)
                        XCTAssertEqual(snapshot.pendingCount, 0)
                        XCTAssertEqual(snapshot.progress, 1)
                    }
                    captured.fulfill()
                }
            }
            probe.didFail = { message in
                XCTFail("Preview failed while capturing resource activity: \(message)")
                captured.fulfill()
            }
            preview.loadLocalFile(page)
        }

        wait(for: [captured], timeout: 5)
        withExtendedLifetime((retainedPreview, retainedProbe)) {}
    }

    func testSafeAreaRotatesWithTheDevice() {
        let portrait = EdgeInsets(top: 62, right: 0, bottom: 34, left: 0)

        XCTAssertEqual(
            SafeAreaGeometry.oriented(portrait, landscape: true),
            EdgeInsets(top: 0, right: 34, bottom: 0, left: 62)
        )
    }

    func testSafariChromeSuppressesAppSafeAreaInsets() {
        let appInsets = EdgeInsets(top: 62, right: 0, bottom: 34, left: 0)

        XCTAssertEqual(
            SafeAreaGeometry.pageInsets(appInsets, landscape: false, safariChrome: true),
            .zero
        )
        XCTAssertEqual(
            SafeAreaGeometry.pageInsets(appInsets, landscape: false, safariChrome: false),
            appInsets
        )
    }

    func testLandscapeSideRailsConsumeTheSafeAreaBeforeThePage() {
        let appInsets = EdgeInsets(top: 62, right: 0, bottom: 34, left: 0)

        XCTAssertEqual(
            SafeAreaGeometry.pageInsets(
                appInsets,
                landscape: true,
                safariChrome: false,
                leftReservedWidth: 118,
                rightReservedWidth: 118
            ),
            .zero
        )
        XCTAssertEqual(
            SafeAreaGeometry.pageInsets(
                appInsets,
                landscape: true,
                safariChrome: false,
                leftReservedWidth: 20,
                rightReservedWidth: 10
            ),
            EdgeInsets(top: 0, right: 24, bottom: 0, left: 42)
        )
    }

    func testPortraitIgnoresReservedSideWidths() {
        let appInsets = EdgeInsets(top: 62, right: 0, bottom: 34, left: 0)

        XCTAssertEqual(
            SafeAreaGeometry.pageInsets(
                appInsets,
                landscape: false,
                safariChrome: false,
                leftReservedWidth: 118,
                rightReservedWidth: 118
            ),
            appInsets
        )
    }

    func testPortraitHeaderConsumesTheTopSafeAreaBeforeThePage() {
        let appInsets = EdgeInsets(top: 62, right: 0, bottom: 34, left: 0)

        XCTAssertEqual(
            SafeAreaGeometry.pageInsets(
                appInsets,
                landscape: false,
                safariChrome: false,
                topReservedHeight: 110
            ),
            EdgeInsets(top: 0, right: 0, bottom: 34, left: 0)
        )
    }

    func testSensorStaysCenteredOnTopInPortrait() throws {
        let device = try XCTUnwrap(BuiltinDevices.all.first { $0.id == "iphone-17-pro-max" })
        let viewportFrame = CGRect(x: 10, y: 10, width: 440, height: 956)

        XCTAssertEqual(
            SensorGeometry.frame(sensor: device.sensor, viewportFrame: viewportFrame, landscape: false),
            CGRect(x: 167, y: 21, width: 126, height: 37)
        )
    }

    func testSensorRotatesOntoLeftEdgeInLandscape() throws {
        let device = try XCTUnwrap(BuiltinDevices.all.first { $0.id == "iphone-17-pro-max" })
        let viewportFrame = CGRect(x: 10, y: 10, width: 956, height: 440)

        XCTAssertEqual(
            SensorGeometry.frame(sensor: device.sensor, viewportFrame: viewportFrame, landscape: true),
            CGRect(x: 21, y: 167, width: 37, height: 126)
        )
    }

    func testPunchHoleRotatesOntoLeftEdgeInLandscape() throws {
        let device = try XCTUnwrap(BuiltinDevices.all.first { $0.id == "pixel-9-pro" })
        let viewportFrame = CGRect(x: 8, y: 8, width: 915, height: 412)

        XCTAssertEqual(
            SensorGeometry.frame(sensor: device.sensor, viewportFrame: viewportFrame, landscape: true),
            CGRect(x: 22, y: 207.5, width: 13, height: 13)
        )
    }

    func testHomeIndicatorRotatesOntoRightEdgeInLandscape() {
        let viewportFrame = CGRect(x: 10, y: 10, width: 956, height: 440)

        XCTAssertEqual(
            HomeIndicatorGeometry.frame(viewportFrame: viewportFrame, landscape: true),
            CGRect(x: 957, y: 178, width: 4, height: 104)
        )
    }

    func testRotatingALoadedPreviewPreservesTheCurrentDocument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewDeckRotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("index.html")
        try """
        <!doctype html>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>rotation state</title>
        <script>
          window.rotationState = { preserved: true, orientationChanges: 0, resizeEvents: 0 };
          window.addEventListener('orientationchange', () => { rotationState.orientationChanges += 1; });
          window.addEventListener('resize', () => { rotationState.resizeEvents += 1; });
        </script>
        """.write(to: file, atomically: true, encoding: .utf8)

        let rotationSettled = expectation(description: "rotation updates without navigation")
        var retainedPreview: DevicePreviewView?
        var retainedProbe: PreviewNavigationProbe?

        DispatchQueue.main.async {
            let preview = DevicePreviewView(profile: BuiltinDevices.all[1])
            let probe = PreviewNavigationProbe()
            retainedPreview = preview
            retainedProbe = probe
            preview.delegate = probe

            var didRotate = false
            probe.didFinish = { _, url in
                guard url?.standardizedFileURL == file.standardizedFileURL, !didRotate else { return }
                didRotate = true
                probe.starts = 0
                probe.finishes = 0
                preview.landscape = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    XCTAssertEqual(probe.starts, 0, "Rotation must not start a new navigation")
                    XCTAssertEqual(probe.finishes, 0, "Rotation must preserve the loaded document")
                    XCTAssertEqual(
                        preview.logicalViewportSize,
                        CGSize(width: 956, height: 440)
                    )
                    guard let webView = firstWebView(in: preview) else {
                        XCTFail("Could not find the preview web view")
                        rotationSettled.fulfill()
                        return
                    }
                    webView.evaluateJavaScript(
                        """
                        JSON.stringify({
                          preserved: window.rotationState?.preserved === true,
                          orientationChanges: window.rotationState?.orientationChanges || 0,
                          resizeEvents: window.rotationState?.resizeEvents || 0,
                          screenWidth: window.screen.width,
                          screenHeight: window.screen.height,
                          safeArea: JSON.parse(document.documentElement.dataset.viewdeckSafeArea || '{}')
                        })
                        """
                    ) { value, error in
                        XCTAssertNil(error)
                        guard let encoded = value as? String,
                              let data = encoded.data(using: .utf8),
                              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            XCTFail("Could not read the live orientation environment")
                            rotationSettled.fulfill()
                            return
                        }
                        XCTAssertEqual(result["preserved"] as? Bool, true)
                        XCTAssertEqual(result["orientationChanges"] as? Int, 1)
                        XCTAssertGreaterThanOrEqual(result["resizeEvents"] as? Int ?? 0, 1)
                        XCTAssertEqual(result["screenWidth"] as? Int, 956)
                        XCTAssertEqual(result["screenHeight"] as? Int, 440)
                        let safeArea = result["safeArea"] as? [String: Any]
                        XCTAssertEqual(safeArea?["top"] as? Int, 0)
                        XCTAssertEqual(safeArea?["right"] as? Int, 34)
                        XCTAssertEqual(safeArea?["bottom"] as? Int, 0)
                        XCTAssertEqual(safeArea?["left"] as? Int, 62)
                        rotationSettled.fulfill()
                    }
                }
            }
            probe.didFail = { message in
                XCTFail("Preview failed while testing rotation: \(message)")
                rotationSettled.fulfill()
            }

            // Let the placeholder navigation from initialization settle before
            // attaching the file whose navigation count this test observes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                preview.loadLocalFile(file)
            }
        }

        wait(for: [rotationSettled], timeout: 5)
        withExtendedLifetime((retainedPreview, retainedProbe)) {}
    }

    func testPhoneProfileEmulatesTouchInputMediaFeatures() throws {
        try assertInputCapabilities(
            deviceID: "iphone-17-pro-max",
            expectedPointer: "coarse",
            expectedHover: "none"
        )
    }

    func testDesktopProfilePreservesFinePointerMediaFeatures() throws {
        try assertInputCapabilities(
            deviceID: "desktop-1440",
            expectedPointer: "fine",
            expectedHover: "hover"
        )
    }

    private func assertInputCapabilities(
        deviceID: String,
        expectedPointer: String,
        expectedHover: String
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewDeckInputCapabilities-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("index.html")
        try """
        <!doctype html>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          #probe { --static-input: unknown; }
          @media (pointer: fine) and (hover: hover) {
            #probe { --static-input: fine; }
          }
          @media (pointer: coarse) and (hover: none) and
                 (any-pointer: coarse) and (any-hover: none) {
            #probe { --static-input: coarse; }
          }
        </style>
        <style media="(pointer: fine)">
          #probe { --attribute-input: fine; }
        </style>
        <style media="(pointer: coarse)">
          #probe { --attribute-input: coarse; }
        </style>
        <div id="probe"></div>
        <script>
          window.immediateStaticInput = getComputedStyle(document.querySelector('#probe'))
            .getPropertyValue('--static-input')
            .trim();
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(`
            @media (pointer: fine) and (hover: hover) {
              #probe { --dynamic-input: fine; }
            }
            @media (pointer: coarse) and (hover: none) {
              #probe { --dynamic-input: coarse; }
            }
            #probe { --literal-query: "(pointer: coarse)"; }
          `);
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        </script>
        """.write(to: file, atomically: true, encoding: .utf8)

        let settled = expectation(description: "\(deviceID) input capabilities settle")
        let device = try XCTUnwrap(BuiltinDevices.all.first { $0.id == deviceID })
        var retainedPreview: DevicePreviewView?
        var retainedProbe: PreviewNavigationProbe?

        DispatchQueue.main.async {
            let preview = DevicePreviewView(profile: device)
            let probe = PreviewNavigationProbe()
            retainedPreview = preview
            retainedProbe = probe
            preview.delegate = probe

            probe.didFinish = { _, url in
                guard url?.standardizedFileURL == file.standardizedFileURL else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard let webView = firstWebView(in: preview) else {
                        XCTFail("Could not find the preview web view")
                        settled.fulfill()
                        return
                    }
                    webView.evaluateJavaScript(
                        """
                        (() => {
                          const style = getComputedStyle(document.querySelector('#probe'));
                          const coarseQuery = matchMedia('(pointer: coarse)');
                          return JSON.stringify({
                            pointerCoarse: coarseQuery.matches,
                            pointerFine: matchMedia('(pointer: fine)').matches,
                            anyPointerCoarse: matchMedia('(any-pointer: coarse)').matches,
                            anyPointerFine: matchMedia('(any-pointer: fine)').matches,
                            hoverNone: matchMedia('(hover: none)').matches,
                            hoverHover: matchMedia('(hover: hover)').matches,
                            anyHoverNone: matchMedia('(any-hover: none)').matches,
                            anyHoverHover: matchMedia('(any-hover: hover)').matches,
                            originalMedia: coarseQuery.media,
                            mediaListIdentity: coarseQuery instanceof MediaQueryList,
                            immediateStaticInput: window.immediateStaticInput,
                            staticInput: style.getPropertyValue('--static-input').trim(),
                            dynamicInput: style.getPropertyValue('--dynamic-input').trim(),
                            attributeInput: style.getPropertyValue('--attribute-input').trim(),
                            literalQuery: style.getPropertyValue('--literal-query').trim()
                          });
                        })()
                        """
                    ) { value, error in
                        XCTAssertNil(error)
                        guard let encoded = value as? String,
                              let data = encoded.data(using: .utf8),
                              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            XCTFail("Could not read the input capability environment")
                            settled.fulfill()
                            return
                        }
                        let expectsCoarse = expectedPointer == "coarse"
                        let expectsNoHover = expectedHover == "none"
                        XCTAssertEqual(result["pointerCoarse"] as? Bool, expectsCoarse)
                        XCTAssertEqual(result["pointerFine"] as? Bool, !expectsCoarse)
                        XCTAssertEqual(result["anyPointerCoarse"] as? Bool, expectsCoarse)
                        XCTAssertEqual(result["anyPointerFine"] as? Bool, !expectsCoarse)
                        XCTAssertEqual(result["hoverNone"] as? Bool, expectsNoHover)
                        XCTAssertEqual(result["hoverHover"] as? Bool, !expectsNoHover)
                        XCTAssertEqual(result["anyHoverNone"] as? Bool, expectsNoHover)
                        XCTAssertEqual(result["anyHoverHover"] as? Bool, !expectsNoHover)
                        XCTAssertEqual(result["originalMedia"] as? String, "(pointer: coarse)")
                        XCTAssertEqual(result["mediaListIdentity"] as? Bool, true)
                        XCTAssertEqual(result["immediateStaticInput"] as? String, expectedPointer)
                        XCTAssertEqual(result["staticInput"] as? String, expectedPointer)
                        XCTAssertEqual(result["dynamicInput"] as? String, expectedPointer)
                        XCTAssertEqual(result["attributeInput"] as? String, expectedPointer)
                        XCTAssertEqual(result["literalQuery"] as? String, "\"(pointer: coarse)\"")
                        settled.fulfill()
                    }
                }
            }
            probe.didFail = { message in
                XCTFail("Preview failed while testing input capabilities: \(message)")
                settled.fulfill()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                preview.loadLocalFile(file)
            }
        }

        wait(for: [settled], timeout: 5)
        withExtendedLifetime((retainedPreview, retainedProbe)) {}
    }

    func testScreenshotExportExpandsToMarkupOutsideTheDevice() {
        let bounds = ScreenshotExportGeometry.contentBounds(
            imageFrame: CGRect(x: 300, y: 200, width: 440, height: 956),
            annotationBounds: [
                CGRect(x: 125, y: 420, width: 90, height: 40),
                CGRect(x: 780, y: 850, width: 120, height: 80)
            ],
            padding: 24,
            constrainedTo: CGRect(x: 0, y: 0, width: 1_600, height: 1_400)
        )

        XCTAssertEqual(bounds, CGRect(x: 101, y: 176, width: 823, height: 1_004))
    }

    func testScreenshotExportPaddingStaysInsideTheWorkspace() {
        let bounds = ScreenshotExportGeometry.contentBounds(
            imageFrame: CGRect(x: 10, y: 15, width: 300, height: 600),
            annotationBounds: [CGRect(x: 0, y: 0, width: 8, height: 8)],
            padding: 24,
            constrainedTo: CGRect(x: 0, y: 0, width: 800, height: 800)
        )

        XCTAssertEqual(bounds, CGRect(x: 0, y: 0, width: 334, height: 639))
    }

    func testScreenshotTextLayoutPreservesSoftWrapping() {
        let font = NSFont.systemFont(ofSize: 22, weight: .medium)
        let value = "Face and body of the hero are covered by the bottom UI, change the composition."
        let singleLine = ScreenshotTextLayout.size(for: value, font: font, layoutWidth: 1_000)
        let wrapped = ScreenshotTextLayout.size(for: value, font: font, layoutWidth: 260)

        XCTAssertEqual(wrapped.width, 260)
        XCTAssertGreaterThan(wrapped.height, singleLine.height * 2)
    }

    func testScreenshotArrowCurveHandleTracksTheVisibleMidpoint() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 0)
        let requestedCurvePoint = CGPoint(x: 50, y: 40)
        let control = ScreenshotArrowGeometry.control(
            start: start,
            curvePoint: requestedCurvePoint,
            end: end
        )

        XCTAssertEqual(
            ScreenshotArrowGeometry.curvePoint(start: start, control: control, end: end),
            requestedCurvePoint
        )
        XCTAssertEqual(control, CGPoint(x: 50, y: 80))
    }

    func testScreenshotArrowBoundsFollowTheRenderedCurve() {
        let bounds = ScreenshotArrowGeometry.bounds(
            start: CGPoint(x: 0, y: 0),
            control: CGPoint(x: 50, y: 80),
            end: CGPoint(x: 100, y: 0)
        )

        XCTAssertEqual(bounds, CGRect(x: 0, y: 0, width: 100, height: 40))
    }

    func testScreenshotStraightArrowRenderedBoundsIncludeTheWholeShaft() {
        let bounds = ScreenshotArrowGeometry.renderedBounds(
            start: CGPoint(x: 0, y: 20),
            control: CGPoint(x: 50, y: 20),
            end: CGPoint(x: 100, y: 20),
            lineWidth: 4
        )

        XCTAssertLessThanOrEqual(bounds.minX, -8)
        XCTAssertGreaterThanOrEqual(bounds.maxX, 108)
        XCTAssertLessThanOrEqual(bounds.minY, 12)
        XCTAssertGreaterThanOrEqual(bounds.maxY, 28)
    }

    func testScreenshotArrowHitTestingFollowsTheCurveInsteadOfTheChord() {
        let start = CGPoint(x: 0, y: 0)
        let control = CGPoint(x: 50, y: 80)
        let end = CGPoint(x: 100, y: 0)

        XCTAssertLessThan(
            ScreenshotArrowGeometry.distance(
                from: CGPoint(x: 50, y: 40),
                toCurveFrom: start,
                control: control,
                end: end
            ),
            0.1
        )
        XCTAssertGreaterThan(
            ScreenshotArrowGeometry.distance(
                from: CGPoint(x: 50, y: 0),
                toCurveFrom: start,
                control: control,
                end: end
            ),
            25
        )
    }

    func testFindsAnANSISplitViteURL() {
        let output = "\u{001B}[32mLocal:\u{001B}[0m http://localhost:\u{001B}[1m5173\u{001B}[0m/"
        XCTAssertEqual(DevServerURLDetector.findURL(in: output)?.absoluteString, "http://localhost:5173/")
    }

    func testNormalizesBindAllAddress() {
        XCTAssertEqual(
            DevServerURLDetector.findURL(in: "ready at http://0.0.0.0:3000/")?.absoluteString,
            "http://localhost:3000/"
        )
    }

    func testLocalServerNavigationBypassesCachedResponses() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:5173/"))
        let request = PreviewNavigationPolicy.request(for: url, bypassCache: true)

        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertTrue(PreviewNavigationPolicy.isLocalDevelopmentURL(url))
    }

    func testLocalWebsiteDataMatchesAcrossLoopbackAliases() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:5173/"))

        XCTAssertTrue(PreviewNavigationPolicy.websiteDataRecord("localhost", matches: url))
        XCTAssertTrue(PreviewNavigationPolicy.websiteDataRecord("127.0.0.1", matches: url))
        XCTAssertFalse(PreviewNavigationPolicy.websiteDataRecord("example.com", matches: url))
    }

    func testWebsiteDataResetIsScopedToTheRecordedSite() throws {
        let game = try XCTUnwrap(URL(string: "https://games.example.com/level/1"))
        let sameGame = try XCTUnwrap(URL(string: "https://games.example.com/ftue"))
        let parentSite = try XCTUnwrap(URL(string: "https://example.com/"))
        let otherSite = try XCTUnwrap(URL(string: "https://example.net/"))
        let localRecording = try XCTUnwrap(URL(string: "http://localhost:5173/"))
        let localReplay = try XCTUnwrap(URL(string: "http://127.0.0.1:5199/"))

        XCTAssertTrue(PreviewNavigationPolicy.websiteDataScopesMatch(game, sameGame))
        XCTAssertTrue(PreviewNavigationPolicy.websiteDataScopesMatch(game, parentSite))
        XCTAssertFalse(PreviewNavigationPolicy.websiteDataScopesMatch(game, otherSite))
        XCTAssertTrue(PreviewNavigationPolicy.websiteDataRecord("example.com", matches: game))
        XCTAssertTrue(PreviewNavigationPolicy.websiteDataScopesMatch(localRecording, localReplay))
        XCTAssertTrue(PreviewNavigationPolicy.websiteDataScopesMatch(
            URL(fileURLWithPath: "/tmp/game/index.html"),
            URL(fileURLWithPath: "/tmp/game/index.html")
        ))
    }

    func testRemoteNavigationIsNotTreatedAsLocalDevelopment() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/"))

        XCTAssertFalse(PreviewNavigationPolicy.isLocalDevelopmentURL(url))
    }

    func testNormalizesWebAddressesWithoutAScheme() {
        XCTAssertEqual(
            PreviewNavigationPolicy.normalizedWebURL(from: "example.com/game/")?.absoluteString,
            "http://example.com/game/"
        )
        XCTAssertEqual(
            PreviewNavigationPolicy.normalizedWebURL(from: "localhost:5173")?.absoluteString,
            "http://localhost:5173"
        )
    }

    func testRejectsInvalidAndUnsupportedAddresses() {
        XCTAssertNil(PreviewNavigationPolicy.normalizedWebURL(from: ""))
        XCTAssertNil(PreviewNavigationPolicy.normalizedWebURL(from: "https://"))
        XCTAssertNil(PreviewNavigationPolicy.normalizedWebURL(from: "not a url"))
        XCTAssertNil(PreviewNavigationPolicy.normalizedWebURL(from: "ftp://example.com/file"))
    }

    func testCancelledNavigationDoesNotReplaceThePreviewWithAnError() {
        XCTAssertTrue(PreviewNavigationPolicy.shouldIgnoreFailure(
            URLError(.cancelled)
        ))
        XCTAssertFalse(PreviewNavigationPolicy.shouldIgnoreFailure(
            URLError(.cannotFindHost)
        ))
    }

    func testUnexpectedBlankCompletionIsTreatedAsAFailedURL() throws {
        let requestedURL = try XCTUnwrap(URL(string: "http://127.0.0.1:1/"))
        let blankURL = try XCTUnwrap(URL(string: "about:blank"))

        XCTAssertTrue(PreviewNavigationPolicy.isUnexpectedBlankCompletion(
            blankURL,
            requestedURL: requestedURL
        ))
        XCTAssertFalse(PreviewNavigationPolicy.isUnexpectedBlankCompletion(
            blankURL,
            requestedURL: nil
        ))
    }

    func testWebLinksThatRequestANewWindowStayInThePreview() throws {
        XCTAssertTrue(PreviewNavigationPolicy.shouldOpenInCurrentPreview(
            try XCTUnwrap(URL(string: "https://example.com/new-tab"))
        ))
        XCTAssertTrue(PreviewNavigationPolicy.shouldOpenInCurrentPreview(
            URL(fileURLWithPath: "/tmp/preview.html")
        ))
        XCTAssertFalse(PreviewNavigationPolicy.shouldOpenInCurrentPreview(
            try XCTUnwrap(URL(string: "mailto:hello@example.com"))
        ))
    }

    func testParsesLocalhostListenersWithSpecificAndWildcardBindings() {
        let listeners = LocalhostPortScanner.parseListeners("""
        p10799
        cnode
        f29
        n127.0.0.1:5183
        p12483
        cnode
        f14
        n*:5183
        """)

        XCTAssertEqual(listeners.count, 2)
        XCTAssertEqual(listeners[0].pid, 10799)
        XCTAssertEqual(listeners[0].endpoint, LocalhostEndpoint(address: "127.0.0.1", port: 5183))
        XCTAssertEqual(listeners[1].endpoint, LocalhostEndpoint(address: "*", port: 5183))
    }

    func testDetectsTwoProcessesSharingTheSamePort() {
        let first = LocalhostProcess(
            pid: 10799,
            parentPID: 10785,
            processName: "node",
            command: "node moonstep/node_modules/.bin/vite",
            parentCommand: "npm run dev",
            workingDirectory: "/games/moonstep",
            endpoints: [LocalhostEndpoint(address: "127.0.0.1", port: 5183)]
        )
        let second = LocalhostProcess(
            pid: 12483,
            parentPID: 12474,
            processName: "node",
            command: "node wreckshot/node_modules/.bin/vite",
            parentCommand: "npm run dev",
            workingDirectory: "/games/wreckshot",
            endpoints: [LocalhostEndpoint(address: "*", port: 5183)]
        )

        XCTAssertEqual(LocalhostPortScanner.collidingPorts(in: [first, second]), [5183])
        XCTAssertEqual(first.displayName, "moonstep")
        XCTAssertEqual(second.displayName, "wreckshot")
    }

    func testSelectsTheNextUnusedPortAndWrapsAtTheEndOfTheRange() {
        XCTAssertEqual(
            LocalhostPortSelection.nextAvailable(after: 5183, occupied: [5183, 5184, 5185]),
            5186
        )
        XCTAssertEqual(
            LocalhostPortSelection.nextAvailable(after: 65_535, occupied: [1024, 1025]),
            1026
        )
    }

    func testRecognizesCommandsThatAcceptAStandardPortOverride() {
        XCTAssertTrue(DevServerPortOverride.isSupported(command: "vite --host 127.0.0.1"))
        XCTAssertTrue(DevServerPortOverride.isSupported(command: "NODE_ENV=development vite"))
        XCTAssertTrue(DevServerPortOverride.isSupported(command: "npm run prepare && node node_modules/vite/bin/vite.js"))
        XCTAssertTrue(DevServerPortOverride.isSupported(command: "next dev"))
        XCTAssertTrue(DevServerPortOverride.isSupported(command: "webpack serve"))
        XCTAssertFalse(DevServerPortOverride.isSupported(command: "next build"))
        XCTAssertFalse(DevServerPortOverride.isSupported(command: "concurrently vite api-server"))
        XCTAssertFalse(DevServerPortOverride.isSupported(command: "node custom-server.mjs"))
    }

    func testFindsPortsInCommonAddressInUseErrors() {
        XCTAssertEqual(
            DevServerPortConflictDetector.findPort(in: "Port 5183 is already in use"),
            5183
        )
        XCTAssertEqual(
            DevServerPortConflictDetector.findPort(
                in: "Error: listen EADDRINUSE: address already in use 127.0.0.1:3000"
            ),
            3000
        )
    }

    func testGUIEnvironmentFindsInstalledNPM() {
        let environment = DevServerEnvironment.make(
            from: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let searchPaths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertTrue(searchPaths.contains("/opt/homebrew/bin"))
        XCTAssertTrue(searchPaths.contains("/usr/local/bin"))
        XCTAssertNotNil(DevServerEnvironment.executable(named: "npm", environment: environment))
    }

    func testStartsDetectsAndStopsNPMServer() throws {
        let controller = DevServerController(environment: [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ])
        let delegate = DevServerTestDelegate()
        let running = expectation(description: "server URL detected")
        let stopped = expectation(description: "server stopped")
        delegate.onState = { state, url in
            if state == .running {
                XCTAssertEqual(url?.host, "localhost")
                XCTAssertNotNil(url?.port)
                running.fulfill()
            }
            if state == .idle, delegate.didRun { stopped.fulfill() }
        }
        controller.delegate = delegate
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/dev-server")

        try controller.start(folder: fixture, script: "dev")
        wait(for: [running], timeout: 10)
        guard let serverURL = delegate.detectedURL else { return XCTFail("Missing detected server URL") }
        assertReachable(serverURL, expected: true)
        XCTAssertThrowsError(try controller.start(folder: fixture, script: "dev")) { error in
            guard let launchError = error as? DevServerLaunchError,
                  case .processStillRunning = launchError else {
                return XCTFail("Expected processStillRunning, got \(error)")
            }
        }
        delegate.didRun = true
        controller.stop()
        wait(for: [stopped], timeout: 5)
        assertReachable(serverURL, expected: false)
    }

    func testAutomaticallyRestartsSupportedServerOnAFreePort() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/dev-server")
        var environment = DevServerEnvironment.make(from: [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ])
        let node = try XCTUnwrap(DevServerEnvironment.executable(named: "node", environment: environment))
        let occupied = try LocalhostPortScanner.listeningPorts()
        let collisionPort = try XCTUnwrap(LocalhostPortSelection.nextAvailable(after: 5182, occupied: occupied))

        let blocker = Process()
        let blockerOutput = Pipe()
        let blockerReady = expectation(description: "existing server is listening")
        blockerReady.assertForOverFulfill = false
        blocker.executableURL = node
        blocker.arguments = [
            "server.mjs", "--host", "127.0.0.1", "--port", String(collisionPort)
        ]
        blocker.currentDirectoryURL = fixture
        blocker.environment = environment
        blocker.standardOutput = blockerOutput
        blocker.standardError = FileHandle.nullDevice
        blockerOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), text.contains(String(collisionPort)) {
                blockerReady.fulfill()
            }
        }
        try blocker.run()
        wait(for: [blockerReady], timeout: 5)
        blockerOutput.fileHandleForReading.readabilityHandler = nil
        defer {
            blockerOutput.fileHandleForReading.readabilityHandler = nil
            if blocker.isRunning {
                blocker.terminate()
                blocker.waitUntilExit()
            }
        }

        func verifyRerouting(host: String, scenario: String) throws {
            environment["VIEWDECK_FIXTURE_PORT"] = String(collisionPort)
            environment["VIEWDECK_FIXTURE_HOST"] = host
            let controller = DevServerController(environment: environment)
            let delegate = DevServerTestDelegate()
            let rerouted = expectation(description: "\(scenario) server rerouted to a free port")
            let retryMessage = expectation(description: "\(scenario) automatic retry is reported")
            let stopped = expectation(description: "\(scenario) rerouted server stopped")
            delegate.onOutput = { line, _ in
                if line.contains("Port \(collisionPort) was already in use") { retryMessage.fulfill() }
            }
            delegate.onState = { state, url in
                if state == .running, let url {
                    XCTAssertNotEqual(url.port, collisionPort)
                    rerouted.fulfill()
                }
                if state == .idle, delegate.didRun { stopped.fulfill() }
            }
            controller.delegate = delegate

            try controller.start(folder: fixture, script: "collision")
            wait(for: [retryMessage, rerouted], timeout: 10)
            XCTAssertNotEqual(controller.serverURL?.port, collisionPort)
            delegate.didRun = true
            controller.stop()
            wait(for: [stopped], timeout: 5)
        }

        try verifyRerouting(host: "::1", scenario: "split loopback")
        try verifyRerouting(host: "127.0.0.1", scenario: "hard bind conflict")
    }

    func testRunsCustomCommandWithoutNPM() throws {
        let controller = DevServerController(environment: [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ])
        let delegate = DevServerTestDelegate()
        let output = expectation(description: "custom command output")
        delegate.onOutput = { line, _ in
            if line.contains("viewdeck-custom-command") { output.fulfill() }
        }
        controller.delegate = delegate

        try controller.startCommand(
            folder: FileManager.default.temporaryDirectory,
            command: "printf 'viewdeck-custom-command\\n'"
        )
        XCTAssertEqual(controller.state, .running)
        wait(for: [output], timeout: 3)
    }

    private func assertReachable(_ url: URL, expected: Bool) {
        let finished = expectation(description: expected ? "server responds" : "server releases port")
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { _, response, error in
            if expected {
                XCTAssertNil(error)
                XCTAssertNotNil(response)
            } else {
                XCTAssertNotNil(error)
            }
            finished.fulfill()
        }.resume()
        wait(for: [finished], timeout: 3)
    }
}

private final class DevServerTestDelegate: DevServerControllerDelegate {
    var didRun = false
    var detectedURL: URL?
    var onState: ((DevServerState, URL?) -> Void)?
    var onOutput: ((String, Bool) -> Void)?

    func devServerStateChanged(_ state: DevServerState, url: URL?) {
        if state == .running { detectedURL = url }
        onState?(state, url)
    }

    func devServerDidOutput(_ line: String, isError: Bool) {
        onOutput?(line, isError)
    }
}
