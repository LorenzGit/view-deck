import Foundation
import XCTest
@testable import ViewDeckCore

final class ViewDeckAppBridgeTests: XCTestCase {
    func testRequestStoreRoundTripsAndConditionallyRemovesRequests() throws {
        let suiteName = "ViewDeckAppBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ViewDeckAppRequestStore(defaults: defaults)
        let request = ViewDeckAppOpenRequest(inspector: "network")

        try store.save(request)
        XCTAssertEqual(try store.load()?.id, request.id)
        XCTAssertEqual(try store.load()?.inspector, request.inspector)

        store.remove(id: "newer-request")
        XCTAssertEqual(try store.load()?.id, request.id)

        store.markApplied(id: request.id)
        XCTAssertNil(try store.load())
        XCTAssertTrue(store.wasApplied(id: request.id))
        store.clearApplied(id: "newer-request")
        XCTAssertTrue(store.wasApplied(id: request.id))
        store.clearApplied(id: request.id)
        XCTAssertFalse(store.wasApplied(id: request.id))
    }

    func testBundleLocatorPrefersAValidExplicitBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewDeckAppBridgeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Configured.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/ViewDeckNative")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))

        XCTAssertEqual(
            ViewDeckAppBundleLocator.locate(
                explicitURL: app,
                executableURL: root.appendingPathComponent("viewdeck")
            ),
            app.standardizedFileURL
        )
    }

    func testBundleLocatorFindsAppBesideCLIAndRejectsInvalidExplicitPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewDeckAppBridgeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("ViewDeck.app", isDirectory: true)
        let appExecutable = app.appendingPathComponent("Contents/MacOS/ViewDeckNative")
        try FileManager.default.createDirectory(
            at: appExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: appExecutable.path, contents: Data()))
        let cli = root.appendingPathComponent("viewdeck")

        XCTAssertEqual(
            ViewDeckAppBundleLocator.locate(explicitURL: nil, executableURL: cli),
            app.standardizedFileURL
        )
        XCTAssertNil(ViewDeckAppBundleLocator.locate(explicitURL: root, executableURL: cli))
    }
}
