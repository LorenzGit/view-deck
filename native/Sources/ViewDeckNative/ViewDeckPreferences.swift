import Foundation

struct ViewDeckPreferences {
    private enum Key {
        static let selectedDevice = "viewdeck.native.selected-device"
        static let landscape = "viewdeck.native.landscape"
        static let inspectorTab = "viewdeck.native.inspector-tab"
        static let projectFolder = "viewdeck.native.project-folder"
        static let networkShaping = "viewdeck.native.network-shaping"
    }

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
        nonmutating set { defaults.set(newValue, forKey: Key.inspectorTab) }
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
        guard (0..<segmentCount).contains(inspectorTabIndex) else { return 0 }
        return inspectorTabIndex
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
