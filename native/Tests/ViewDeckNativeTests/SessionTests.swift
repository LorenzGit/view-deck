import Foundation
import XCTest
@testable import ViewDeckCore

final class SessionTests: XCTestCase {
    private let id = "8c43f7f1-43f9-46d0-b4a2-b12f2cbca9cf"

    func testNestedHelpDoesNotRequireASourceOrLaunchAHost() {
        XCTAssertEqual(ViewDeckCommand.run(arguments: ["session", "start", "--help"]), 0)
        XCTAssertEqual(ViewDeckCommand.run(arguments: ["session", "record", "start", "--help"]), 0)
        XCTAssertEqual(ViewDeckCommand.run(arguments: ["session", "click", id, "--help"]), 0)
    }

    func testInvocationRejectsInvalidIDsFlagsAndUnboundedNumbers() throws {
        XCTAssertThrowsError(try SessionInvocation.parse(["status", "../../other"]))
        XCTAssertThrowsError(try SessionInvocation.parse(["click", id, "--wrong", "3"]))
        XCTAssertThrowsError(try SessionInvocation.parse(["click", id, "--x", "nan", "--y", "2"]))
        XCTAssertThrowsError(try SessionInvocation.parse(["status", id, "--timeout", "10000"]))
        let command = try SessionInvocation.parse(["click", id.uppercased(), "--x", "12", "--y", "30", "--json"])
        XCTAssertEqual(command.session, id)
        XCTAssertEqual(command.params["x"], .number(12))
        XCTAssertEqual(command.params["y"], .number(30))
        XCTAssertEqual(try SessionInvocation.parse(["record", "start", id, "--output", "video.mp4"]).method, "record.start")
    }

    func testStoreRejectsSharedAndSymlinkedControlDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let link = root.appendingPathExtension("link")
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: root) }
        _ = try SessionStore(root: root)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try SessionStore(root: link))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try SessionStore(root: root))
    }

    func testIndependentCLICommandsKeepStateAndDeliverTrustedInput() throws {
        let session = try start()
        defer { close(session) }
        let status = try result(["status", session])
        let preview = try XCTUnwrap(status["preview"] as? [String: Any])
        XCTAssertEqual(preview["visibility"] as? String, "hidden")
        XCTAssertEqual(preview["windowIntersectsDisplay"] as? Bool, false)
        XCTAssertEqual((status["audio"] as? [String: Any])?["muteApplied"] as? Bool, true)
        _ = try result(["click", session, "--selector", "#increment"])
        _ = try result(["click", session, "--selector", "#increment"])
        _ = try result(["type", session, "--selector", "#name", "--text", "Agent player"])
        _ = try result(["key", session, "--key", "ArrowRight", "--action", "down"])
        XCTAssertEqual(try result(["status", session])["heldKeys"] as? [String], ["ArrowRight"])
        _ = try result(["key", session, "--key", "ArrowRight", "--action", "up"])
        let value = try XCTUnwrap(try evaluate(session, "({count, name:document.querySelector('#name').value, events})") as? [String: Any])
        XCTAssertEqual(value["count"] as? Int, 2)
        XCTAssertEqual(value["name"] as? String, "Agent player")
        let events = try XCTUnwrap(value["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains { $0["type"] as? String == "click" })
        XCTAssertTrue(events.contains { $0["type"] as? String == "input" })
        XCTAssertTrue(events.contains { $0["type"] as? String == "keydown" && $0["key"] as? String == "ArrowRight" })
        XCTAssertTrue(events.allSatisfy { $0["trusted"] as? Bool == true }, "Input must use WebKit's native event path")
        _ = try result(["drag", session, "--from-x", "20", "--from-y", "260", "--to-x", "180", "--to-y", "290"])
        let points = try XCTUnwrap(try evaluate(session, "dragPoints") as? [[String: Any]])
        XCTAssertTrue(points.contains { $0["type"] as? String == "pointerdown" })
        XCTAssertTrue(points.contains { $0["type"] as? String == "pointermove" && $0["buttons"] as? Int == 1 })
        XCTAssertTrue(points.contains { ($0["movementX"] as? Double ?? 0) > 0 })
        XCTAssertTrue(points.contains { $0["type"] as? String == "pointerup" && $0["buttons"] as? Int == 0 })
        XCTAssertTrue(points.allSatisfy { $0["trusted"] as? Bool == true })
        _ = try result(["reload", session])
        XCTAssertEqual(try evaluate(session, "count") as? Int, 2, "Reload keeps session storage")
        let other = try start()
        defer { close(other) }
        XCTAssertEqual(try evaluate(other, "count") as? Int, 0, "Sessions must have independent storage")
        _ = try evaluate(session, "new Promise(resolve => setTimeout(() => resolve('async result'), 20))")
        let expired = try call(["wait", session, "--selector", "#missing", "--timeout", "0.2"], expectedStatus: 1)
        XCTAssertEqual((expired["error"] as? [String: Any])?["code"] as? String, "timeout")
        XCTAssertEqual(try evaluate(session, "count") as? Int, 2, "An expired wait must not destroy the session")
    }

    func testSessionProducesArtifactsAndClosesActiveRecording() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try start()
        defer { close(session) }
        let screenshot = directory.appendingPathComponent("frame.png")
        let captured = try result(["screenshot", session, "--output", screenshot.path, "--scale", "2"])
        XCTAssertEqual(captured["width"] as? Int, 750)
        XCTAssertEqual(captured["height"] as? Int, 1334)
        let video = directory.appendingPathComponent("recording.mp4")
        _ = try result(["record", "start", session, "--output", video.path, "--scale", "1", "--fps", "10"])
        _ = try result(["click", session, "--selector", "#increment"])
        _ = try result(["wait", session, "--seconds", "0.4"])
        let stopped = try result(["record", "stop", session])
        XCTAssertEqual(stopped["state"] as? String, "saved")
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: video.path)[.size] as? NSNumber)?.intValue ?? 0, 1000)
        _ = try result(["configure", session, "--orientation", "landscape"])
        XCTAssertEqual(try result(["status", session])["orientation"] as? String, "landscape")
        let audit = try result(["inspect", session])
        XCTAssertNotNil(audit["audit"])
        let finalVideo = directory.appendingPathComponent("auto-saved.mp4")
        _ = try result(["record", "start", session, "--output", finalVideo.path, "--scale", "1", "--fps", "10"])
        _ = try result(["wait", session, "--seconds", "0.3"])
        let closed = try result(["stop", session])
        XCTAssertEqual(closed["state"] as? String, "closed")
        XCTAssertEqual((closed["recording"] as? [String: Any])?["state"] as? String, "saved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalVideo.path))
    }

    func testSessionIdleExpiryStopsItsManagedServer() throws {
        let project = fixture.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dev-server")
        let started = try call(["start", "--project", project.path, "--command", "node server.mjs", "--device", "iphone-se", "--idle-timeout", "5"])
        let session = try XCTUnwrap(started["session"] as? String)
        defer { close(session) }
        let value = try XCTUnwrap(started["result"] as? [String: Any])
        let port = try XCTUnwrap(URL(string: try XCTUnwrap(value["url"] as? String))?.port)
        Thread.sleep(forTimeInterval: 8.5)
        let response = try call(["status", session], expectedStatus: 2)
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "session_closed")
        XCTAssertFalse(try LocalhostPortScanner.listeningPorts().contains(port))
    }

    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/session/index.html")
    }

    private func start() throws -> String {
        try XCTUnwrap(call(["start", "--file", fixture.path, "--device", "iphone-se", "--wait-for", "#increment"])["session"] as? String)
    }

    private func close(_ session: String) {
        _ = try? call(["stop", session])
        try? SessionStore().remove(session)
    }

    private func evaluate(_ session: String, _ source: String) throws -> Any? {
        try result(["eval", session, "--js", source])["value"]
    }

    private func result(_ args: [String]) throws -> [String: Any] {
        try XCTUnwrap(call(args)["result"] as? [String: Any])
    }

    private func call(_ args: [String], expectedStatus: Int32 = 0) throws -> [String: Any] {
        let native = fixture.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [native.appendingPathComponent(".build/out/Products/Debug/viewdeck"),
                          native.appendingPathComponent(".build/debug/viewdeck")]
        let executable = try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process()
        process.executableURL = executable
        process.arguments = ["session"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let expiry = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: expiry)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        expiry.cancel()
        XCTAssertEqual(process.terminationStatus, expectedStatus, "\(args): \(String(decoding: data, as: UTF8.self))")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
