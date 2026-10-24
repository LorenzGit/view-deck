import AppKit
import XCTest
@testable import ViewDeckCore

final class DeckSegmentedControlTests: XCTestCase {
    @MainActor
    func testFocusedTabsDoNotDrawTheNativeCellFocusRing() throws {
        let (window, control, probe) = fixture(labels: ["Device", "Server", "Ports", "Network"])
        defer { window.close() }
        XCTAssertEqual(control.focusRingType, .none)
        try click(control, at: NSPoint(x: 120, y: 27))
        XCTAssertTrue(window.firstResponder === control)
        XCTAssertEqual(control.selectedSegment, 1)
        XCTAssertEqual(probe.selections, [1])
        XCTAssertEqual(control.focusRingType, .none)
    }

    @MainActor
    func testClicksMatchDrawnTabsAcrossInspectorWidths() throws {
        let (window, control, probe) = fixture(labels: ["Device", "Server", "Ports", "Network"])
        defer { window.close() }

        for width: CGFloat in [260, 320, 457, 640] {
            control.setFrameSize(NSSize(width: width, height: 54))
            for index in [3, 0, 2, 1] {
                for fraction: CGFloat in [0.02, 0.5, 0.98] {
                    for y: CGFloat in [1, 27, 53] {
                        let point = NSPoint(x: (CGFloat(index) + fraction) * width / 4, y: y)
                        let previousActions = probe.selections.count
                        try click(control, at: point)
                        XCTAssertEqual(control.selectedSegment, index, "width=\(width), point=\(point)")
                        XCTAssertEqual(probe.selections.last, index)
                        XCTAssertEqual(probe.selections.count, previousActions + 1)
                    }
                }
            }
        }
    }

    @MainActor
    func testOrientationUsesTheSameClickGeometry() throws {
        let (window, control, probe) = fixture(labels: ["Portrait", "Landscape"])
        defer { window.close() }
        control.setFrameSize(NSSize(width: 150, height: 34))
        for index in [1, 0, 1] {
            try click(control, at: NSPoint(x: CGFloat(index) * 75 + 37.5, y: 17))
            XCTAssertEqual(control.selectedSegment, index)
        }
        XCTAssertEqual(probe.selections, [1, 0, 1])
    }

    @MainActor
    func testDisabledTabsAndCancelledClicksDoNotSendActions() throws {
        let (window, control, probe) = fixture(labels: ["Device", "Server", "Ports", "Network"])
        defer { window.close() }
        control.setEnabled(false, forSegment: 1)
        try click(control, at: NSPoint(x: 120, y: 27))
        control.isEnabled = false
        try click(control, at: NSPoint(x: 280, y: 27))
        control.isEnabled = true
        try click(control, at: NSPoint(x: 280, y: 27), releaseAt: NSPoint(x: 120, y: 27))
        try click(control, at: NSPoint(x: 280, y: 27), releaseAt: NSPoint(x: 321, y: 27))
        XCTAssertEqual(control.selectedSegment, 0)
        XCTAssertTrue(probe.selections.isEmpty)
    }

    @MainActor
    private func fixture(labels: [String]) -> (NSWindow, DeckSegmentedControl, SegmentActionProbe) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let probe = SegmentActionProbe()
        let control = DeckSegmentedControl(labels: labels, trackingMode: .selectOne,
                                           target: probe, action: #selector(SegmentActionProbe.changed(_:)))
        control.frame = NSRect(x: 25, y: 20, width: 320, height: 54)
        control.selectedSegment = 0
        window.contentView?.addSubview(control)
        return (window, control, probe)
    }

    @MainActor
    private func click(_ control: DeckSegmentedControl, at point: NSPoint, releaseAt: NSPoint? = nil) throws {
        let window = try XCTUnwrap(control.window)
        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: control.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        let down = try event(.leftMouseDown, at: point)
        NSApp.postEvent(try event(.leftMouseUp, at: releaseAt ?? point), atStart: true)
        control.mouseDown(with: down)
        // Disabled controls do not enter the tracking loop.
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    }
}

@MainActor
private final class SegmentActionProbe: NSObject {
    var selections: [Int] = []

    @objc func changed(_ sender: NSSegmentedControl) {
        selections.append(sender.selectedSegment)
    }
}
