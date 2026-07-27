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
            "--wait-for", "canvas",
            "--prepare-js", "window.testMode = true",
            "--output", "/tmp/game.png",
            "--report", "/tmp/game.json",
            "--video", "/tmp/game.mp4",
            "--duration", "4",
            "--fps", "12",
            "--json"
        ])

        XCTAssertEqual(invocation.operation, .capture)
        XCTAssertEqual(invocation.project?.path, "/tmp/game")
        XCTAssertEqual(invocation.npmScript, "dev")
        XCTAssertEqual(invocation.route, "/play")
        XCTAssertEqual(invocation.deviceID, "iphone-16-pro")
        XCTAssertTrue(invocation.landscape)
        XCTAssertEqual(invocation.waitSelector, "canvas")
        XCTAssertEqual(invocation.prepareJavaScript, "window.testMode = true")
        XCTAssertEqual(invocation.screenshotOutput?.path, "/tmp/game.png")
        XCTAssertEqual(invocation.reportOutput?.path, "/tmp/game.json")
        XCTAssertEqual(invocation.videoOutput?.path, "/tmp/game.mp4")
        XCTAssertEqual(invocation.videoDuration, 4)
        XCTAssertEqual(invocation.videoFPS, 12)
        XCTAssertTrue(invocation.json)
    }

    func testProjectDefaultsToDevScript() throws {
        let invocation = try CLIInvocation.parse([
            "inspect",
            "--project", "/tmp/game"
        ])

        XCTAssertEqual(invocation.npmScript, "dev")
        XCTAssertEqual(invocation.videoFPS, 30)
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
}
