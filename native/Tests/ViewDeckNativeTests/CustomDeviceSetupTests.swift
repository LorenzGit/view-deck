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
            header: CustomDeviceLayerSelection(identifier: "header-id", extent: 52),
            footer: CustomDeviceLayerSelection(identifier: "footer-id", extent: 60),
            left: CustomDeviceLayerSelection(identifier: "left-id", extent: 124),
            right: CustomDeviceLayerSelection(identifier: "right-id", extent: 132)
        )
        let model = DeviceEditorModel(setup: setup)

        model.name = "Edited setup"
        model.landscape = false
        model.rightLayerID = DeviceEditorModel.noLayerID
        model.leftExtent = "140"
        let edited = model.makeSetup()

        XCTAssertEqual(edited.id, setup.id)
        XCTAssertEqual(edited.profile.name, "Edited setup")
        XCTAssertFalse(edited.profile.builtin)
        XCTAssertFalse(edited.landscape)
        XCTAssertEqual(edited.header, setup.header)
        XCTAssertEqual(edited.footer, setup.footer)
        XCTAssertEqual(edited.left.identifier, "left-id")
        XCTAssertEqual(edited.left.extent, 140)
        XCTAssertNil(edited.right.identifier)
        XCTAssertEqual(edited.right.extent, 132)
    }

    func testNewCustomSetupEncodingRoundTripsWithoutMigration() throws {
        var profile = BuiltinDevices.all[2]
        profile.id = "round-trip"
        profile.builtin = false
        let setup = CustomDeviceSetup(
            id: profile.id,
            profile: profile,
            landscape: true,
            left: CustomDeviceLayerSelection(identifier: "rail", extent: 144)
        )

        let decoded = CustomDeviceSetupStore.decode(try JSONEncoder().encode([setup]))

        XCTAssertEqual(decoded, [setup])
    }
}
