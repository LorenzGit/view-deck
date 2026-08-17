import AppKit
import Foundation

struct ViewDeckAppOpenRequest: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var id = UUID().uuidString
    var configuration: QADeviceConfiguration?
    var source: QASourceConfiguration?
    var inspector: String?
}

struct ViewDeckAppRequestStore {
    static let bundleIdentifier = AppInfo.bundleIdentifier
    static let notificationName = Notification.Name("studio.viewdeck.native.open-request")

    private static let requestKey = "viewdeck.native.app-open-request"
    private static let appliedRequestKey = "viewdeck.native.applied-app-open-request"
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.bundleIdentifier) ?? .standard
    }

    func save(_ request: ViewDeckAppOpenRequest) throws {
        defaults.set(try JSONEncoder().encode(request), forKey: Self.requestKey)
        _ = defaults.synchronize()
    }

    func load() throws -> ViewDeckAppOpenRequest? {
        guard let data = defaults.data(forKey: Self.requestKey) else { return nil }
        return try JSONDecoder().decode(ViewDeckAppOpenRequest.self, from: data)
    }

    func remove(id: String? = nil) {
        if let id, (try? load())?.id != id { return }
        defaults.removeObject(forKey: Self.requestKey)
    }

    func markApplied(id: String) {
        defaults.set(id, forKey: Self.appliedRequestKey)
        remove(id: id)
        _ = defaults.synchronize()
    }

    func wasApplied(id: String) -> Bool {
        _ = defaults.synchronize()
        return defaults.string(forKey: Self.appliedRequestKey) == id
    }

    func clearApplied(id: String) {
        guard defaults.string(forKey: Self.appliedRequestKey) == id else { return }
        defaults.removeObject(forKey: Self.appliedRequestKey)
    }
}

enum ViewDeckAppBundleLocator {
    static func locate(
        explicitURL: URL?,
        executableURL: URL,
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) -> URL? {
        if let explicitURL {
            return isViewDeckApp(explicitURL, fileManager: fileManager)
                ? explicitURL.standardizedFileURL
                : nil
        }

        let sibling = executableURL.standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("ViewDeck.app", isDirectory: true)
        if isViewDeckApp(sibling, fileManager: fileManager) { return sibling }

        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: ViewDeckAppRequestStore.bundleIdentifier
        ).first?.bundleURL,
           isViewDeckApp(running, fileManager: fileManager) {
            return running.standardizedFileURL
        }

        guard let registered = workspace.urlForApplication(
            withBundleIdentifier: ViewDeckAppRequestStore.bundleIdentifier
        ), isViewDeckApp(registered, fileManager: fileManager) else { return nil }
        return registered.standardizedFileURL
    }

    static func isViewDeckApp(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard url.pathExtension.lowercased() == "app",
              fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return fileManager.fileExists(
            atPath: url.appendingPathComponent("Contents/MacOS/ViewDeckNative").path
        )
    }
}
