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
}
