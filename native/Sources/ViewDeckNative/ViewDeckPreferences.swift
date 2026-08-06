import Foundation

struct ViewDeckPreferences {
    private enum Key {
        static let selectedDevice = "viewdeck.native.selected-device"
        static let inspectorTab = "viewdeck.native.inspector-tab"
        static let inspectorTabLayoutVersion = "viewdeck.native.inspector-tab-layout-version"
        static let projectFolder = "viewdeck.native.project-folder"
        static let projectHistory = "viewdeck.native.project-history"
        static let networkShaping = "viewdeck.native.network-shaping"
    }

    private static let currentInspectorTabLayoutVersion = 3
    private static let maximumProjectHistoryCount = 10

    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    var selectedDeviceID: String? {
        get { defaults.string(forKey: Key.selectedDevice) }
        nonmutating set { defaults.set(newValue, forKey: Key.selectedDevice) }
    }

    var inspectorTabIndex: Int {
        get { defaults.integer(forKey: Key.inspectorTab) }
        nonmutating set {
            defaults.set(newValue, forKey: Key.inspectorTab)
            defaults.set(
                Self.currentInspectorTabLayoutVersion,
                forKey: Key.inspectorTabLayoutVersion
            )
        }
    }

    var networkShapingConfiguration: NetworkShapingConfiguration {
        get {
            guard let data = defaults.data(forKey: Key.networkShaping),
                  let configuration = try? JSONDecoder().decode(
                    NetworkShapingConfiguration.self,
                    from: data
                  ) else {
                return .disabled
            }
            return configuration.normalized
        }
        nonmutating set {
            let configuration = newValue.normalized
            if let data = try? JSONEncoder().encode(configuration) {
                defaults.set(data, forKey: Key.networkShaping)
            }
        }
    }

    func inspectorTabIndex(segmentCount: Int) -> Int {
        let storedIndex = inspectorTabIndex
        let storedVersion = defaults.integer(forKey: Key.inspectorTabLayoutVersion)
        var version = storedVersion
        var index = storedIndex
        if version < 2 {
            // Safe area moved into Device. Later tabs shift left by one.
            index = storedIndex <= 1 ? 0 : storedIndex - 1
            version = 2
        }
        if version < 3 {
            // Layers moved into Device. Later tabs shift left by one.
            index = index <= 1 ? 0 : index - 1
            version = 3
        }
        if version != storedVersion {
            defaults.set(index, forKey: Key.inspectorTab)
            defaults.set(version, forKey: Key.inspectorTabLayoutVersion)
        }
        return (0..<segmentCount).contains(index) ? index : 0
    }

    var projectFolderURL: URL? {
        get {
            guard let path = defaults.string(forKey: Key.projectFolder), !path.isEmpty else { return nil }
            return existingDirectoryURL(for: path)
        }
        nonmutating set {
            if let newValue {
                let folder = newValue.standardizedFileURL
                defaults.set(folder.path, forKey: Key.projectFolder)
                recordProjectSelection(folder)
            } else {
                defaults.removeObject(forKey: Key.projectFolder)
            }
        }
    }

    var projectHistoryURLs: [URL] {
        let storedPaths = defaults.stringArray(forKey: Key.projectHistory) ?? []
        var seenPaths = Set<String>()
        let folders = storedPaths.compactMap { path -> URL? in
            guard let folder = existingDirectoryURL(for: path),
                  seenPaths.insert(folder.path).inserted else { return nil }
            return folder
        }
        let recentFolders = Array(folders.prefix(Self.maximumProjectHistoryCount))
        let recentPaths = recentFolders.map(\.path)
        if recentPaths != storedPaths {
            defaults.set(recentPaths, forKey: Key.projectHistory)
        }
        return recentFolders
    }

    private func recordProjectSelection(_ folder: URL) {
        let previousFolders = projectHistoryURLs.filter { $0.path != folder.path }
        defaults.set(
            Array(([folder] + previousFolders).prefix(Self.maximumProjectHistoryCount)).map(\.path),
            forKey: Key.projectHistory
        )
    }

    private func existingDirectoryURL(for path: String) -> URL? {
        let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return folder
    }
}
