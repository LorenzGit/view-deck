import AppKit
import WebKit
import XCTest
@testable import ViewDeckCore

final class PreviewKeyboardTests: XCTestCase {
    @MainActor
    func testGameKeysReachPageWithoutEscapingToWindow() async throws {
        _ = NSApplication.shared
        let preview = DevicePreviewView(profile: BuiltinDevices.all[0])
        let window = KeyboardProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = preview
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        func findWebView(_ view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.compactMap(findWebView).first
        }
        let webView = try XCTUnwrap(findWebView(preview))
        let navigation = KeyboardNavigationDelegate()
        webView.navigationDelegate = navigation
        webView.loadHTMLString("""
        <!doctype html><input id="name"><canvas tabindex="0" id="game"></canvas>
        <script>
        window.keys = [];
        for (const type of ['keydown', 'keyup']) {
          addEventListener(type, e => keys.push({type, key: e.key, repeat: e.repeat}));
        }
        </script>
        """, baseURL: nil)
        await fulfillment(of: [navigation.loaded], timeout: 10)
        XCTAssertTrue(window.makeFirstResponder(webView))
        _ = try await webView.evaluateJavaScript("document.getElementById('game').focus()")

        func send(_ type: NSEvent.EventType, key: String, code: UInt16, repeatKey: Bool = false,
                  modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: repeatKey, keyCode: code
            ))
            NSApp.sendEvent(event)
        }
        try send(.keyDown, key: "w", code: 13)
        try send(.keyDown, key: "w", code: 13, repeatKey: true)
        try send(.keyUp, key: "w", code: 13)
        // WebKit delivers DOM events and resends unhandled keys asynchronously.
        try await Task.sleep(for: .milliseconds(500))
        let recordedKeys = try await webView.evaluateJavaScript("keys")
        let keys = try XCTUnwrap(recordedKeys as? [[String: Any]])
        XCTAssertEqual(keys.compactMap { $0["type"] as? String }, ["keydown", "keydown", "keyup"])
        XCTAssertEqual(keys.compactMap { $0["key"] as? String }, ["w", "w", "w"])
        XCTAssertEqual(keys.compactMap { $0["repeat"] as? Bool }, [false, true, false])
        XCTAssertTrue(window.unhandledKeys.isEmpty, "Unhandled game keys would reach the system beep: \(window.unhandledKeys)")

        _ = try await webView.evaluateJavaScript("document.getElementById('name').focus()")
        try send(.keyDown, key: "a", code: 0)
        try send(.keyUp, key: "a", code: 0)
        try await Task.sleep(for: .milliseconds(500))
        let value = try await webView.evaluateJavaScript("document.getElementById('name').value")
        XCTAssertEqual(value as? String, "a", "Native text input must still work")

        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Keyboard test", action: #selector(KeyboardProbeWindow.shortcut), keyEquivalent: "r")
        item.target = window
        item.keyEquivalentModifierMask = .command
        NSApp.mainMenu = menu
        try send(.keyDown, key: "r", code: 15, modifiers: .command)
        XCTAssertEqual(window.shortcutCount, 1, "Command menu shortcuts must still work with preview focus")
        withExtendedLifetime(navigation) {}
    }
}

@MainActor
private final class KeyboardProbeWindow: NSWindow {
    var unhandledKeys: [String] = []
    var shortcutCount = 0

    @objc func shortcut() {
        shortcutCount += 1
    }

    override func keyDown(with event: NSEvent) {
        unhandledKeys.append(event.characters ?? "")
    }
}

@MainActor
private final class KeyboardNavigationDelegate: NSObject, WKNavigationDelegate {
    let loaded = XCTestExpectation(description: "keyboard fixture loaded")

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }
}
