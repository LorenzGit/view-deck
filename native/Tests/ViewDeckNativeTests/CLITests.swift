import Foundation
import XCTest
@testable import ViewDeckCore

final class CLITests: XCTestCase {
    func testCaptureInvocationParsesAgentWorkflowOptions() throws {
        let invocation = try CLIInvocation.parse([
            "capture",
            "--project", "/tmp/game",
            "--npm-script", "dev",
            "--path", "/play",
            "--device", "iphone-16-pro",
            "--orientation", "landscape",
            "--left", "/tmp/left.html",
            "--left-width", "118",
            "--right", "/tmp/right.html",
            "--right-width", "120",
            "--wait-for", "canvas",
            "--prepare-js", "window.testMode = true",
            "--output", "/tmp/game.png",
            "--report", "/tmp/game.json",
            "--video", "/tmp/game.mp4",
            "--duration", "4",
            "--fps", "12",
            "--show-preview",
            "--json"
        ])

        XCTAssertEqual(invocation.operation, .capture)
        XCTAssertEqual(invocation.project?.path, "/tmp/game")
        XCTAssertEqual(invocation.npmScript, "dev")
        XCTAssertEqual(invocation.route, "/play")
        XCTAssertEqual(invocation.deviceID, "iphone-16-pro")
        XCTAssertTrue(invocation.landscape)
        XCTAssertEqual(invocation.leftFile?.path, "/tmp/left.html")
        XCTAssertEqual(invocation.leftWidth, 118)
        XCTAssertEqual(invocation.rightFile?.path, "/tmp/right.html")
        XCTAssertEqual(invocation.rightWidth, 120)
        XCTAssertEqual(invocation.waitSelector, "canvas")
        XCTAssertEqual(invocation.prepareJavaScript, "window.testMode = true")
        XCTAssertEqual(invocation.screenshotOutput?.path, "/tmp/game.png")
        XCTAssertEqual(invocation.reportOutput?.path, "/tmp/game.json")
        XCTAssertEqual(invocation.videoOutput?.path, "/tmp/game.mp4")
        XCTAssertEqual(invocation.videoDuration, 4)
        XCTAssertEqual(invocation.videoFPS, 12)
        XCTAssertTrue(invocation.showPreview)
        XCTAssertTrue(invocation.json)
    }

    func testProjectDefaultsToDevScript() throws {
        let invocation = try CLIInvocation.parse([
            "inspect",
            "--project", "/tmp/game"
        ])

        XCTAssertEqual(invocation.npmScript, "dev")
        XCTAssertEqual(invocation.videoFPS, 30)
        XCTAssertFalse(invocation.showPreview)
        XCTAssertEqual(invocation.audioMode, .normal)
        XCTAssertFalse(invocation.networkShapingConfiguration.enabled)
    }

    func testNetworkShapingOptionsParseForDirectAndReplayCommands() throws {
        let direct = try CLIInvocation.parse([
            "inspect", "https://example.com",
            "--network-rtt-ms", "420",
            "--network-jitter-ms", "35",
            "--network-down-kbps", "1200",
            "--network-up-kbps", "320",
            "--network-seed", "99"
        ])

        XCTAssertTrue(direct.hasNetworkShapingOverride)
        XCTAssertEqual(direct.networkShapingConfiguration, NetworkShapingConfiguration(
            enabled: true,
            roundTripTimeMilliseconds: 420,
            jitterMilliseconds: 35,
            downloadKilobitsPerSecond: 1_200,
            uploadKilobitsPerSecond: 320,
            offline: false,
            seed: 99
        ))

        let replay = try CLIInvocation.parse([
            "qa", "replay", "/tmp/gameplay.viewdeck.json",
            "--network-offline"
        ])
        XCTAssertTrue(replay.hasNetworkShapingOverride)
        XCTAssertTrue(replay.networkShapingConfiguration.enabled)
        XCTAssertTrue(replay.networkShapingConfiguration.offline)
    }

    func testNetworkShapingRejectsInvalidValues() {
        XCTAssertThrowsError(try CLIInvocation.parse([
            "inspect", "https://example.com",
            "--network-rtt-ms", "-1"
        ]))
        XCTAssertThrowsError(try CLIInvocation.parse([
            "inspect", "https://example.com",
            "--network-seed", "2.5"
        ]))
        XCTAssertThrowsError(try CLIInvocation.parse([
            "inspect", "https://example.com",
            "--network-down-kbps", "inf"
        ]))
        XCTAssertThrowsError(try CLIInvocation.parse([
            "inspect", "https://example.com",
            "--network-seed", "18446744073709551615"
        ]))
    }

    func testNativeHTTPOptionsAreOptInRepeatableAndStrictlyHostOnly() throws {
        let invocation = try CLIInvocation.parse([
            "inspect", "https://app.example.com",
            "--native-http",
            "--native-http-allow-host", "API.EXAMPLE.COM.",
            "--native-http-allow-host", "api.example.com",
            "--native-http-allow-host", "127.0.0.1"
        ])

        XCTAssertTrue(invocation.nativeHTTPConfiguration.enabled)
        XCTAssertTrue(invocation.hasNativeHTTPOverride)
        XCTAssertEqual(invocation.nativeHTTPConfiguration.allowedHosts, [
            "api.example.com", "127.0.0.1"
        ])

        for invalidHost in [
            "https://api.example.com", "api.example.com:443", "api.example.com/path",
            "user@api.example.com", "*.example.com"
        ] {
            XCTAssertThrowsError(try CLIInvocation.parse([
                "inspect", "https://app.example.com",
                "--native-http-allow-host", invalidHost
            ]))
        }
    }

    func testNativeHTTPLeavesHiddenAndVerifySilentPoliciesUnchanged() throws {
        let invocation = try CLIInvocation.parse([
            "inspect", "https://app.example.com",
            "--native-http",
            "--native-http-allow-host", "api.example.com",
            "--audio", "verify-silent"
        ])

        XCTAssertFalse(invocation.showPreview)
        XCTAssertEqual(invocation.audioMode, .verifySilent)
        XCTAssertThrowsError(try CLIInvocation.parse([
            "inspect", "https://app.example.com",
            "--native-http",
            "--native-http-allow-host", "api.example.com",
            "--audio", "verify-silent",
            "--show-preview"
        ]))
    }

    func testHiddenPreviewParsesSilentAudioVerification() throws {
        let invocation = try CLIInvocation.parse([
            "inspect",
            "--project", "/tmp/game",
            "--audio", "verify-silent"
        ])

        XCTAssertEqual(invocation.audioMode, .verifySilent)
        XCTAssertFalse(invocation.showPreview)
    }

    func testSilentAudioVerificationRejectsVisiblePreview() {
        XCTAssertThrowsError(try CLIInvocation.parse([
            "inspect",
            "--project", "/tmp/game",
            "--audio", "verify-silent",
            "--show-preview"
        ]))
    }

    func testAudioModeRejectsUnknownValue() {
        XCTAssertThrowsError(try CLIInvocation.parse([
            "inspect",
            "--project", "/tmp/game",
            "--audio", "silent"
        ]))
    }

    func testHiddenPreviewOriginStaysOutsideEveryDisplay() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
            CGRect(x: -1_920, y: -100, width: 1_920, height: 1_080),
            CGRect(x: 1_440, y: 200, width: 2_560, height: 1_440)
        ]
        let size = CGSize(width: 430, height: 932)

        let origin = CLIPreviewWindow.origin(
            showPreview: false,
            windowSize: size,
            screenFrames: screens,
            mainVisibleFrame: screens[0]
        )
        let windowFrame = CGRect(origin: origin, size: size)

        XCTAssertEqual(windowFrame.maxX, -1_920 - CLIPreviewWindow.offscreenMargin)
        XCTAssertFalse(screens.contains { $0.intersects(windowFrame) })
    }

    func testVisiblePreviewOriginAnchorsToMainDisplayBottomTrailingCorner() {
        let visibleFrame = CGRect(x: 10, y: 40, width: 1_400, height: 830)
        let size = CGSize(width: 430, height: 820)

        let origin = CLIPreviewWindow.origin(
            showPreview: true,
            windowSize: size,
            screenFrames: [visibleFrame],
            mainVisibleFrame: visibleFrame
        )

        XCTAssertEqual(origin.x, visibleFrame.maxX - size.width)
        XCTAssertEqual(origin.y, visibleFrame.minY)
    }

    func testCaptureRequiresPNGOutput() {
        XCTAssertThrowsError(try CLIInvocation.parse([
            "capture",
            "http://localhost:5173"
        ]))
        XCTAssertThrowsError(try CLIInvocation.parse([
            "capture",
            "http://localhost:5173",
            "--output", "/tmp/capture.jpg"
        ]))
    }

    func testRouteReplacesTheLoadedURLPath() throws {
        let base = try XCTUnwrap(URL(string: "http://localhost:5173/old?value=1"))
        let result = CLIPath.appending(route: "/game/start", to: base)

        XCTAssertEqual(result.absoluteString, "http://localhost:5173/game/start?value=1")
    }

    func testQAReplayInvocationParsesTimingAndArtifacts() throws {
        let invocation = try CLIInvocation.parse([
            "qa", "replay", "/tmp/gameplay.viewdeck.json",
            "--speed", "2",
            "--artifacts", "/tmp/qa-artifacts",
            "--video", "/tmp/replay.mp4",
            "--screenshot", "/tmp/final.png",
            "--report", "/tmp/replay.json",
            "--fps", "15",
            "--json"
        ])

        XCTAssertEqual(invocation.operation, .qaReplay)
        XCTAssertEqual(invocation.scenarioInput?.path, "/tmp/gameplay.viewdeck.json")
        XCTAssertEqual(invocation.playbackSpeed, 2)
        XCTAssertEqual(invocation.artifactDirectory?.path, "/tmp/qa-artifacts")
        XCTAssertEqual(invocation.videoOutput?.path, "/tmp/replay.mp4")
        XCTAssertEqual(invocation.screenshotOutput?.path, "/tmp/final.png")
        XCTAssertEqual(invocation.reportOutput?.path, "/tmp/replay.json")
        XCTAssertEqual(invocation.videoFPS, 15)
        XCTAssertTrue(invocation.json)
    }

    func testQAReplaySupportsMaximumSpeed() throws {
        let invocation = try CLIInvocation.parse([
            "qa", "replay", "/tmp/gameplay.viewdeck.json",
            "--speed", "max"
        ])

        XCTAssertEqual(invocation.playbackSpeed, 0)
    }

    func testQAReplaySupportsSmartTiming() throws {
        let invocation = try CLIInvocation.parse([
            "qa", "replay", "/tmp/gameplay.viewdeck.json",
            "--speed", "smart"
        ])

        XCTAssertTrue(invocation.smartPlayback)
        XCTAssertEqual(invocation.playbackSpeed, 1)
    }

    func testQATemplateParsesSourceDeviceAndOutput() throws {
        let invocation = try CLIInvocation.parse([
            "qa", "template",
            "http://localhost:5173",
            "--device", "iphone-16-pro",
            "--orientation", "landscape",
            "--name", "keyboard smoke test",
            "--output", "/tmp/keyboard.viewdeck.json",
            "--overwrite",
            "--json"
        ])

        XCTAssertEqual(invocation.operation, .qaTemplate)
        XCTAssertEqual(invocation.sourceURL, "http://localhost:5173")
        XCTAssertEqual(invocation.deviceID, "iphone-16-pro")
        XCTAssertTrue(invocation.landscape)
        XCTAssertEqual(invocation.scenarioName, "keyboard smoke test")
        XCTAssertEqual(invocation.scenarioOutput?.path, "/tmp/keyboard.viewdeck.json")
        XCTAssertTrue(invocation.overwrite)
        XCTAssertTrue(invocation.json)
    }

    func testQATemplateRequiresJSONOutput() {
        XCTAssertThrowsError(try CLIInvocation.parse([
            "qa", "template",
            "http://localhost:5173"
        ]))
        XCTAssertThrowsError(try CLIInvocation.parse([
            "qa", "template",
            "http://localhost:5173",
            "--output", "/tmp/scenario.txt"
        ]))
    }

    func testQATemplateAndReplayPreserveNativeHTTPConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewDeckNativeHTTPTemplate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("native-http.viewdeck.json")

        XCTAssertEqual(ViewDeckCommand.run(arguments: [
            "qa", "template", "https://app.example.com",
            "--native-http",
            "--native-http-allow-host", "api.example.com",
            "--native-http-allow-host", "assets.example.com",
            "--output", output.path,
            "--overwrite"
        ]), 0)

        let scenario = try QAScenarioFiles.load(output)
        XCTAssertEqual(scenario.configuration.nativeHTTP, NativeHTTPConfiguration(
            enabled: true,
            allowedHosts: ["api.example.com", "assets.example.com"]
        ))
        let replay = try CLIInvocation.parse(["qa", "replay", output.path])
        let effective = CLIReplayConfiguration.effective(scenario: scenario, invocation: replay)
        XCTAssertEqual(effective.nativeHTTP, scenario.configuration.nativeHTTP)
    }
}
