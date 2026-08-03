import Foundation

struct ViewDeckPreferences {
    private enum Key {
        static let selectedDevice = "viewdeck.native.selected-device"
        static let landscape = "viewdeck.native.landscape"
        static let inspectorTab = "viewdeck.native.inspector-tab"
        static let inspectorTabLayoutVersion = "viewdeck.native.inspector-tab-layout-version"
        static let projectFolder = "viewdeck.native.project-folder"
        static let networkShaping = "viewdeck.native.network-shaping"
    }

    private static let currentInspectorTabLayoutVersion = 3

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

    var isLandscape: Bool {
        get { defaults.bool(forKey: Key.landscape) }
        nonmutating set { defaults.set(newValue, forKey: Key.landscape) }
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
            let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return folder
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.standardizedFileURL.path, forKey: Key.projectFolder)
            } else {
                defaults.removeObject(forKey: Key.projectFolder)
            }
        }
    }
}
