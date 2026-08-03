import Foundation
import XCTest
@testable import ViewDeckCore

final class CustomDeviceSetupTests: XCTestCase {
    func testMigratesLegacyCustomDeviceProfilesWithoutChangingTheirIdentity() throws {
        var legacyProfile = BuiltinDevices.all[1]
        legacyProfile.id = "legacy-custom"
        legacyProfile.name = "Legacy custom"
        legacyProfile.builtin = false

        let setups = CustomDeviceSetupStore.decode(try JSONEncoder().encode([legacyProfile]))

        let setup = try XCTUnwrap(setups.first)
        XCTAssertEqual(setups.count, 1)
        XCTAssertEqual(setup.id, legacyProfile.id)
        XCTAssertEqual(setup.profile, legacyProfile)
        XCTAssertFalse(setup.landscape)
        XCTAssertFalse(setup.showSafeArea)
        XCTAssertFalse(setup.applySafeAreaToPage)
        XCTAssertNil(setup.header.identifier)
        XCTAssertEqual(setup.header.extent, HTMLLayerKind.header.defaultExtent)
        XCTAssertNil(setup.left.identifier)
        XCTAssertEqual(setup.left.extent, HTMLLayerKind.left.defaultExtent)
    }

    func testEditorRoundTripsOrientationAndEveryLayerSelection() {
        var profile = BuiltinDevices.all[0]
        profile.id = "custom-landscape"
        profile.name = "Landscape game"
        profile.builtin = false
        let setup = CustomDeviceSetup(
            id: profile.id,
            profile: profile,
            landscape: true,
            showSafeArea: true,
            applySafeAreaToPage: true,
            header: CustomDeviceLayerSelection(identifier: "header-id", extent: 52),
            footer: CustomDeviceLayerSelection(identifier: "footer-id", extent: 60),
            left: CustomDeviceLayerSelection(identifier: "left-id", extent: 124),
            right: CustomDeviceLayerSelection(identifier: "right-id", extent: 132)
        )
        let model = DeviceEditorModel(setup: setup)

        model.name = "Edited setup"
        model.landscape = false
        model.showSafeArea = false
        model.rightLayerID = DeviceEditorModel.noLayerID
        model.leftExtent = "140"
        let edited = model.makeSetup()

        XCTAssertEqual(edited.id, setup.id)
        XCTAssertEqual(edited.profile.name, "Edited setup")
        XCTAssertFalse(edited.profile.builtin)
        XCTAssertFalse(edited.landscape)
        XCTAssertFalse(edited.showSafeArea)
        XCTAssertTrue(edited.applySafeAreaToPage)
        XCTAssertEqual(edited.header, setup.header)
        XCTAssertEqual(edited.footer, setup.footer)
        XCTAssertEqual(edited.left.identifier, "left-id")
        XCTAssertEqual(edited.left.extent, 140)
        XCTAssertNil(edited.right.identifier)
        XCTAssertEqual(edited.right.extent, 132)
    }

    func testEditorPersistsTheCompleteDeviceSkin() {
        var profile = BuiltinDevices.all[1]
        profile.id = "custom-skin"
        profile.builtin = false
        let model = DeviceEditorModel(
            setup: CustomDeviceSetup(id: profile.id, profile: profile, landscape: false)
        )

        model.platform = DevicePlatform.android.rawValue
        model.viewportWidth = "480"
        model.viewportHeight = "960"
        model.dpr = "2.5"
        model.shellTop = "12"
        model.shellRight = "13"
        model.shellBottom = "14"
        model.shellLeft = "15"
        model.cornerRadius = "48"
        model.safeTop = "32"
        model.safeRight = "2"
        model.safeBottom = "24"
        model.safeLeft = "3"
        model.sensorType = SensorType.punch.rawValue
        model.sensorWidth = "14"
        model.sensorHeight = "15"
        model.sensorTop = "16"
        model.safariChrome = true
        model.homeIndicator = false
        model.landscape = true
        model.showSafeArea = true
        model.applySafeAreaToPage = true

        let edited = model.makeSetup()

        XCTAssertEqual(edited.profile.platform, .android)
        XCTAssertEqual(edited.profile.viewport, Viewport(width: 480, height: 960, dpr: 2.5))
        XCTAssertEqual(edited.profile.shell, DeviceShell(top: 12, right: 13, bottom: 14, left: 15, radius: 48))
        XCTAssertEqual(edited.profile.safeArea, EdgeInsets(top: 32, right: 2, bottom: 24, left: 3))
        XCTAssertEqual(edited.profile.sensor, DeviceSensor(type: .punch, width: 14, height: 15, top: 16))
        XCTAssertTrue(edited.profile.safariChrome)
        XCTAssertFalse(edited.profile.homeIndicator)
        XCTAssertTrue(edited.landscape)
        XCTAssertTrue(edited.showSafeArea)
        XCTAssertTrue(edited.applySafeAreaToPage)
    }

    func testNewCustomSetupEncodingRoundTripsWithoutMigration() throws {
        var profile = BuiltinDevices.all[2]
        profile.id = "round-trip"
        profile.builtin = false
        let setup = CustomDeviceSetup(
            id: profile.id,
            profile: profile,
            landscape: true,
            showSafeArea: true,
            applySafeAreaToPage: true,
            left: CustomDeviceLayerSelection(identifier: "rail", extent: 144)
        )

        let decoded = CustomDeviceSetupStore.decode(try JSONEncoder().encode([setup]))

        XCTAssertEqual(decoded, [setup])
    }

    func testDuplicateRetainsEverySettingWithNewCustomIdentity() {
        var profile = BuiltinDevices.all[1]
        let setup = CustomDeviceSetup(
            id: profile.id,
            profile: profile,
            landscape: true,
            showSafeArea: true,
            applySafeAreaToPage: true,
            header: CustomDeviceLayerSelection(identifier: "header-id", extent: 64),
            footer: CustomDeviceLayerSelection(identifier: "footer-id", extent: 72),
            left: CustomDeviceLayerSelection(identifier: "left-id", extent: 128),
            right: CustomDeviceLayerSelection(identifier: "right-id", extent: 136)
        )

        let duplicate = setup.duplicated(id: "duplicate-id")

        profile.id = "duplicate-id"
        profile.name += " Copy"
        profile.builtin = false
        XCTAssertEqual(
            duplicate,
            CustomDeviceSetup(
                id: "duplicate-id",
                profile: profile,
                landscape: setup.landscape,
                showSafeArea: setup.showSafeArea,
                applySafeAreaToPage: setup.applySafeAreaToPage,
                header: setup.header,
                footer: setup.footer,
                left: setup.left,
                right: setup.right
            )
        )
    }

    func testDecodesSavedSetupFromBeforeSafeAreaBehaviorBecameDeviceSettings() throws {
        var profile = BuiltinDevices.all[1]
        profile.id = "legacy-setup"
        profile.builtin = false
        let setup = CustomDeviceSetup(id: profile.id, profile: profile, landscape: true)
        var encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode([setup])) as? [[String: Any]]
        )
        encoded[0].removeValue(forKey: "showSafeArea")
        encoded[0].removeValue(forKey: "applySafeAreaToPage")

        let decoded = CustomDeviceSetupStore.decode(
            try JSONSerialization.data(withJSONObject: encoded)
        )

        XCTAssertEqual(decoded.count, 1)
        XCTAssertFalse(decoded[0].showSafeArea)
        XCTAssertFalse(decoded[0].applySafeAreaToPage)
    }

    func testStorePersistsAnEditedCompleteSetup() {
        let suiteName = "CustomDeviceSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var profile = BuiltinDevices.all[1]
        profile.id = "saved-custom"
        profile.name = "Saved custom"
        profile.builtin = false
        let setup = CustomDeviceSetup(
            id: profile.id,
            profile: profile,
            landscape: true,
            showSafeArea: true,
            applySafeAreaToPage: true,
            header: CustomDeviceLayerSelection(identifier: "header-id", extent: 64),
            footer: CustomDeviceLayerSelection(identifier: "footer-id", extent: 72),
            left: CustomDeviceLayerSelection(identifier: "left-id", extent: 128),
            right: CustomDeviceLayerSelection(identifier: "right-id", extent: 136)
        )

        CustomDeviceSetupStore.save([setup], store: defaults)

        XCTAssertEqual(CustomDeviceSetupStore.load(store: defaults), [setup])
    }
}
