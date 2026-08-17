import AppKit

public enum ViewDeckApplication {
    public static func run() {
        AppDelegate.run()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    static func run() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        _ = delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        installMainMenu()
        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appOpenRequestReceived(_:)),
            name: ViewDeckAppRequestStore.notificationName,
            object: ViewDeckAppRequestStore.bundleIdentifier,
            suspensionBehavior: .deliverImmediately
        )
        applyPendingAppOpenRequest()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        mainWindowController?.stopServices()
    }

    @objc private func appOpenRequestReceived(_ notification: Notification) {
        applyPendingAppOpenRequest()
    }

    private func applyPendingAppOpenRequest() {
        let store = ViewDeckAppRequestStore()
        do {
            guard let request = try store.load() else { return }
            guard request.schemaVersion == ViewDeckAppOpenRequest.currentSchemaVersion else {
                store.remove(id: request.id)
                return
            }
            mainWindowController?.applyAppOpenRequest(request)
            store.markApplied(id: request.id)
        } catch {
            store.remove()
            ViewDeckCommand.writeError("Could not apply app-open request: \(error.localizedDescription)")
        }
    }

    private func installMainMenu() {
        let menu = NSMenu()
        NSApp.mainMenu = menu

        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About ViewDeck", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ViewDeck", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ViewDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Device Library",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .control]
        toggleSidebarItem.target = self
        viewMenu.addItem(toggleSidebarItem)
        let toggleInspectorItem = NSMenuItem(
            title: "Toggle Inspector",
            action: #selector(toggleInspector(_:)),
            keyEquivalent: "i"
        )
        toggleInspectorItem.keyEquivalentModifierMask = [.command, .control]
        toggleInspectorItem.target = self
        viewMenu.addItem(toggleInspectorItem)

        let windowItem = NSMenuItem()
        menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        mainWindowController?.toggleSidebar()
    }

    @objc private func toggleInspector(_ sender: Any?) {
        mainWindowController?.toggleInspector()
    }
}
