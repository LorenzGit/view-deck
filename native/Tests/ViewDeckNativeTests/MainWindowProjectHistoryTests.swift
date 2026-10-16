import AppKit
import XCTest
@testable import ViewDeckCore

final class MainWindowProjectHistoryTests: XCTestCase {
    @MainActor
    func testRestoresProjectDeviceAndOrientationThroughWindowControlsAndRelaunch() throws {
        _ = NSApplication.shared
        let suiteName = "MainWindowProjectHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = (0..<3).map { root.appendingPathComponent("game-\($0)", isDirectory: true) }
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let phone = try XCTUnwrap(BuiltinDevices.all.first { $0.id == "iphone-17-pro-max" })
        let otherDevice = try XCTUnwrap(BuiltinDevices.all.first { $0.id != phone.id })
        let preferences = ViewDeckPreferences(defaults: defaults)
        preferences.rememberDevice(phone.id, landscape: true, forProject: folders[0])
        preferences.rememberDevice(phone.id, landscape: false, forProject: folders[1])
        preferences.rememberDevice(otherDevice.id, landscape: true, forProject: folders[2])
        for folder in folders { preferences.projectFolderURL = folder }
        preferences.projectFolderURL = folders[0]

        let controller = MainWindowController(preferences: preferences)
        defer { controller.stopServices(); controller.window?.close() }
        XCTAssertEqual(controller.canvas.preview.profile.id, phone.id)
        XCTAssertTrue(controller.canvas.preview.landscape, "Startup restores the project's orientation")

        let popup = NSPopUpButton()
        func selectProject(_ folder: URL) {
            popup.removeAllItems()
            popup.addItem(withTitle: folder.lastPathComponent)
            popup.lastItem?.representedObject = folder.path
            controller.perform(NSSelectorFromString("projectHistorySelected:"), with: popup)
        }
        selectProject(folders[1])
        XCTAssertEqual(controller.canvas.preview.profile.id, phone.id)
        XCTAssertFalse(controller.canvas.preview.landscape, "The same device can have another orientation")

        controller.perform(NSSelectorFromString("rotateDevice"))
        XCTAssertEqual(preferences.lastLandscape(forProject: folders[1]), true)

        let orientation = NSSegmentedControl(labels: ["Portrait", "Landscape"], trackingMode: .selectOne, target: nil, action: nil)
        orientation.selectedSegment = 0
        controller.perform(NSSelectorFromString("inspectorOrientationChanged:"), with: orientation)
        XCTAssertEqual(preferences.lastLandscape(forProject: folders[1]), false)

        selectProject(folders[2])
        XCTAssertEqual(controller.canvas.preview.profile.id, otherDevice.id)
        XCTAssertTrue(controller.canvas.preview.landscape)
        selectProject(folders[0])
        XCTAssertEqual(controller.canvas.preview.profile.id, phone.id)
        XCTAssertTrue(controller.canvas.preview.landscape)
        selectProject(folders[1])
        XCTAssertFalse(controller.canvas.preview.landscape)

        let reopened = MainWindowController(preferences: preferences)
        defer { reopened.stopServices(); reopened.window?.close() }
        XCTAssertEqual(reopened.canvas.preview.profile.id, phone.id)
        XCTAssertFalse(reopened.canvas.preview.landscape, "Relaunch restores the last project's saved orientation")
    }
}
