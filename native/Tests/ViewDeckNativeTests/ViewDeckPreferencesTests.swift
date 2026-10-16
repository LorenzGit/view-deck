import Foundation
import XCTest
@testable import ViewDeckCore

final class ViewDeckPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ViewDeckPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPersistsSelectedDeviceAndInspectorTab() {
        let preferences = ViewDeckPreferences(defaults: defaults)

        preferences.selectedDeviceID = "iphone-17-pro-max"
        preferences.inspectorTabIndex = 3

        let restored = ViewDeckPreferences(defaults: defaults)
        XCTAssertEqual(restored.selectedDeviceID, "iphone-17-pro-max")
        XCTAssertEqual(restored.inspectorTabIndex(segmentCount: 4), 3)
    }

    func testFallsBackToDeviceTabForInvalidSavedTab() {
        let preferences = ViewDeckPreferences(defaults: defaults)

        preferences.inspectorTabIndex = 4

        XCTAssertEqual(preferences.inspectorTabIndex(segmentCount: 4), 0)
    }

    func testMigratesLegacySafeAreaTabIntoDevicePanel() {
        defaults.set(1, forKey: "viewdeck.native.inspector-tab")

        let preferences = ViewDeckPreferences(defaults: defaults)

        XCTAssertEqual(preferences.inspectorTabIndex(segmentCount: 4), 0)
        XCTAssertEqual(preferences.inspectorTabIndex, 0)
    }

    func testShiftsLegacyTabsAfterMergedSafeAreaAndLayers() {
        defaults.set(5, forKey: "viewdeck.native.inspector-tab")

        let preferences = ViewDeckPreferences(defaults: defaults)

        XCTAssertEqual(preferences.inspectorTabIndex(segmentCount: 4), 3)
        XCTAssertEqual(preferences.inspectorTabIndex, 3)
    }

    func testMigratesVersionTwoLayersTabIntoDevicePanel() {
        defaults.set(1, forKey: "viewdeck.native.inspector-tab")
        defaults.set(2, forKey: "viewdeck.native.inspector-tab-layout-version")

        let preferences = ViewDeckPreferences(defaults: defaults)

        XCTAssertEqual(preferences.inspectorTabIndex(segmentCount: 4), 0)
        XCTAssertEqual(preferences.inspectorTabIndex, 0)
    }

    func testShiftsVersionTwoTabsAfterLayersIntoTheirNewPositions() {
        defaults.set(4, forKey: "viewdeck.native.inspector-tab")
        defaults.set(2, forKey: "viewdeck.native.inspector-tab-layout-version")

        let preferences = ViewDeckPreferences(defaults: defaults)

        XCTAssertEqual(preferences.inspectorTabIndex(segmentCount: 4), 3)
        XCTAssertEqual(preferences.inspectorTabIndex, 3)
    }

    func testPersistsNetworkShapingConfiguration() {
        let preferences = ViewDeckPreferences(defaults: defaults)
        let configuration = NetworkShapingConfiguration(
            enabled: true,
            roundTripTimeMilliseconds: 420,
            jitterMilliseconds: 35,
            downloadKilobitsPerSecond: 1_200,
            uploadKilobitsPerSecond: 320,
            offline: false,
            seed: 99
        )

        preferences.networkShapingConfiguration = configuration

        XCTAssertEqual(
            ViewDeckPreferences(defaults: defaults).networkShapingConfiguration,
            configuration
        )
    }

    func testNativeHTTPIsDisabledByDefaultAndPersistsExplicitConfiguration() {
        let preferences = ViewDeckPreferences(defaults: defaults)
        XCTAssertEqual(preferences.nativeHTTPConfiguration, .disabled)

        let configuration = NativeHTTPConfiguration(
            enabled: true,
            allowedHosts: ["API.EXAMPLE.COM", "assets.example.com"]
        )
        preferences.nativeHTTPConfiguration = configuration

        XCTAssertEqual(
            ViewDeckPreferences(defaults: defaults).nativeHTTPConfiguration,
            NativeHTTPConfiguration(
                enabled: true,
                allowedHosts: ["api.example.com", "assets.example.com"]
            )
        )
    }

    func testRestoresExistingProjectDirectory() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewDeckPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let preferences = ViewDeckPreferences(defaults: defaults)
        preferences.projectFolderURL = folder

        XCTAssertEqual(preferences.projectFolderURL, folder.standardizedFileURL)
    }

    func testIgnoresMissingProjectDirectory() {
        let preferences = ViewDeckPreferences(defaults: defaults)
        let missingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewDeckPreferencesTests-missing-\(UUID().uuidString)", isDirectory: true)

        preferences.projectFolderURL = missingFolder

        XCTAssertNil(preferences.projectFolderURL)
    }

    func testOrdersProjectHistoryByMostRecentSelection() throws {
        let folders = try makeTemporaryProjectFolders(count: 2)
        defer { try? FileManager.default.removeItem(at: folders[0].deletingLastPathComponent()) }
        let preferences = ViewDeckPreferences(defaults: defaults)

        preferences.projectFolderURL = folders[0]
        preferences.projectFolderURL = folders[1]
        preferences.projectFolderURL = folders[0]

        XCTAssertEqual(preferences.projectHistoryURLs, [folders[0], folders[1]].map(\.standardizedFileURL))
    }

    func testCapsProjectHistoryAtTenSelections() throws {
        let folders = try makeTemporaryProjectFolders(count: 11)
        defer { try? FileManager.default.removeItem(at: folders[0].deletingLastPathComponent()) }
        let preferences = ViewDeckPreferences(defaults: defaults)

        for folder in folders {
            preferences.projectFolderURL = folder
        }

        XCTAssertEqual(preferences.projectHistoryURLs, Array(folders.reversed().prefix(10)).map(\.standardizedFileURL))
    }

    func testRemovesMissingProjectsFromHistory() throws {
        let folders = try makeTemporaryProjectFolders(count: 2)
        defer { try? FileManager.default.removeItem(at: folders[0].deletingLastPathComponent()) }
        let preferences = ViewDeckPreferences(defaults: defaults)
        preferences.projectFolderURL = folders[0]
        preferences.projectFolderURL = folders[1]

        try FileManager.default.removeItem(at: folders[1])

        XCTAssertEqual(preferences.projectHistoryURLs, [folders[0].standardizedFileURL])
        XCTAssertEqual(
            defaults.stringArray(forKey: "viewdeck.native.project-history"),
            [folders[0].standardizedFileURL.path]
        )
    }

    func testRemembersLastDeviceAndOrientationForEachProjectAcrossReloads() throws {
        let folders = try makeTemporaryProjectFolders(count: 2)
        defer { try? FileManager.default.removeItem(at: folders[0].deletingLastPathComponent()) }
        let preferences = ViewDeckPreferences(defaults: defaults)

        preferences.rememberDevice("iphone-17-pro-max", landscape: false, forProject: folders[0])
        preferences.rememberDevice("ipad-pro-13", landscape: false, forProject: folders[1])
        preferences.rememberDevice("macbook-pro-16", landscape: true, forProject: folders[0])

        let restored = ViewDeckPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        XCTAssertEqual(restored.lastDeviceID(forProject: folders[0]), "macbook-pro-16")
        XCTAssertEqual(restored.lastLandscape(forProject: folders[0]), true)
        XCTAssertEqual(restored.lastDeviceID(forProject: folders[1]), "ipad-pro-13")
        XCTAssertEqual(restored.lastLandscape(forProject: folders[1]), false)
    }

    func testProjectsUsingTheSameDeviceKeepIndependentOrientations() throws {
        let folders = try makeTemporaryProjectFolders(count: 2)
        defer { try? FileManager.default.removeItem(at: folders[0].deletingLastPathComponent()) }
        let preferences = ViewDeckPreferences(defaults: defaults)

        preferences.rememberDevice("iphone-17-pro-max", landscape: true, forProject: folders[0])
        preferences.rememberDevice("iphone-17-pro-max", landscape: false, forProject: folders[1])
        preferences.rememberDevice("iphone-17-pro-max", landscape: false, forProject: folders[0])

        XCTAssertEqual(preferences.lastLandscape(forProject: folders[0]), false)
        XCTAssertEqual(preferences.lastLandscape(forProject: folders[1]), false)
        preferences.rememberDevice("iphone-17-pro-max", landscape: true, forProject: folders[1])
        XCTAssertEqual(preferences.lastLandscape(forProject: folders[0]), false)
        XCTAssertEqual(preferences.lastLandscape(forProject: folders[1]), true)
    }

    func testLegacyDeviceHistoryHasNoSavedOrientationUntilUpdated() throws {
        let folder = try makeTemporaryProjectFolders(count: 1)[0]
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        defaults.set(
            [folder.standardizedFileURL.path: "iphone-17-pro-max"],
            forKey: "viewdeck.native.project-device-history"
        )
        let preferences = ViewDeckPreferences(defaults: defaults)

        XCTAssertEqual(preferences.lastDeviceID(forProject: folder), "iphone-17-pro-max")
        XCTAssertNil(preferences.lastLandscape(forProject: folder))

        preferences.rememberDevice("iphone-17-pro-max", landscape: true, forProject: folder)

        XCTAssertEqual(preferences.lastLandscape(forProject: folder), true)
    }

    func testDeviceHistoryUsesStandardizedProjectPaths() throws {
        let folder = try makeTemporaryProjectFolders(count: 1)[0]
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let equivalentFolder = folder.appendingPathComponent("../project-0", isDirectory: true)
        let preferences = ViewDeckPreferences(defaults: defaults)

        preferences.rememberDevice("iphone-17-pro-max", landscape: true, forProject: equivalentFolder)

        XCTAssertEqual(preferences.lastDeviceID(forProject: folder), "iphone-17-pro-max")
        XCTAssertEqual(preferences.lastLandscape(forProject: folder), true)
    }

    private func makeTemporaryProjectFolders(count: Int) throws -> [URL] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewDeckPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let folder = root.appendingPathComponent("project-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
    }
}
