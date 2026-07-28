import AppKit
import Foundation

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0"
    }
}

struct EdgeInsets: Codable, Equatable {
    var top: CGFloat
    var right: CGFloat
    var bottom: CGFloat
    var left: CGFloat

    static let zero = EdgeInsets(top: 0, right: 0, bottom: 0, left: 0)
}

struct Viewport: Codable, Equatable {
    var width: CGFloat
    var height: CGFloat
    var dpr: CGFloat
}

struct DeviceShell: Codable, Equatable {
    var top: CGFloat
    var right: CGFloat
    var bottom: CGFloat
    var left: CGFloat
    var radius: CGFloat
}

enum SensorType: String, Codable, CaseIterable {
    case island
    case notch
    case punch
    case none
}

struct DeviceSensor: Codable, Equatable {
    var type: SensorType
    var width: CGFloat
    var height: CGFloat
    var top: CGFloat
}

enum DevicePlatform: String, Codable, CaseIterable {
    case iOS
    case android = "Android"
    case tablet = "Tablet"
    case desktop = "Desktop"
    case custom = "Custom"
}

struct DeviceProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var platform: DevicePlatform
    var viewport: Viewport
    var shell: DeviceShell
    var safeArea: EdgeInsets
    var sensor: DeviceSensor
    var safariChrome: Bool
    var homeIndicator: Bool
    var builtin: Bool

    var mobile: Bool { platform == .iOS || platform == .android || platform == .tablet }

    var userAgent: String {
        switch platform {
        case .iOS:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        case .android:
            return "Mozilla/5.0 (Linux; Android 16; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
        case .tablet:
            return "Mozilla/5.0 (iPad; CPU OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        case .desktop, .custom:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        }
    }
}

enum BuiltinDevices {
    static let all: [DeviceProfile] = [
        DeviceProfile(
            id: "iphone-17-pro-max-safari",
            name: "iPhone 17 Pro Max · Safari",
            platform: .iOS,
            viewport: Viewport(width: 440, height: 956, dpr: 3),
            shell: DeviceShell(top: 10, right: 10, bottom: 10, left: 10, radius: 61),
            safeArea: .zero,
            sensor: DeviceSensor(type: .island, width: 126, height: 37, top: 11),
            safariChrome: true,
            homeIndicator: true,
            builtin: true
        ),
        DeviceProfile(
            id: "iphone-17-pro-max",
            name: "iPhone 17 Pro Max · App",
            platform: .iOS,
            viewport: Viewport(width: 440, height: 956, dpr: 3),
            shell: DeviceShell(top: 10, right: 10, bottom: 10, left: 10, radius: 61),
            safeArea: EdgeInsets(top: 62, right: 0, bottom: 34, left: 0),
            sensor: DeviceSensor(type: .island, width: 126, height: 37, top: 11),
            safariChrome: false,
            homeIndicator: true,
            builtin: true
        ),
        DeviceProfile(
            id: "iphone-16-pro-safari",
            name: "iPhone 16 Pro · Safari",
            platform: .iOS,
            viewport: Viewport(width: 393, height: 852, dpr: 3),
            shell: DeviceShell(top: 10, right: 10, bottom: 10, left: 10, radius: 57),
            safeArea: .zero,
            sensor: DeviceSensor(type: .island, width: 126, height: 37, top: 11),
            safariChrome: true,
            homeIndicator: true,
            builtin: true
        ),
        DeviceProfile(
            id: "iphone-16-pro",
            name: "iPhone 16 Pro · App",
            platform: .iOS,
            viewport: Viewport(width: 393, height: 852, dpr: 3),
            shell: DeviceShell(top: 10, right: 10, bottom: 10, left: 10, radius: 57),
            safeArea: EdgeInsets(top: 59, right: 0, bottom: 34, left: 0),
            sensor: DeviceSensor(type: .island, width: 126, height: 37, top: 11),
            safariChrome: false,
            homeIndicator: true,
            builtin: true
        ),
        DeviceProfile(
            id: "iphone-se",
            name: "iPhone SE",
            platform: .iOS,
            viewport: Viewport(width: 375, height: 667, dpr: 2),
            shell: DeviceShell(top: 55, right: 12, bottom: 55, left: 12, radius: 37),
            safeArea: EdgeInsets(top: 20, right: 0, bottom: 0, left: 0),
            sensor: DeviceSensor(type: .none, width: 0, height: 0, top: 0),
            safariChrome: false,
            homeIndicator: false,
            builtin: true
        ),
        DeviceProfile(
            id: "pixel-9-pro",
            name: "Pixel 9 Pro · WebKit check",
            platform: .android,
            viewport: Viewport(width: 412, height: 915, dpr: 2.625),
            shell: DeviceShell(top: 8, right: 8, bottom: 8, left: 8, radius: 48),
            safeArea: EdgeInsets(top: 32, right: 0, bottom: 24, left: 0),
            sensor: DeviceSensor(type: .punch, width: 13, height: 13, top: 14),
            safariChrome: false,
            homeIndicator: true,
            builtin: true
        ),
        DeviceProfile(
            id: "ipad-pro-13",
            name: "iPad Pro 13″ · Safari",
            platform: .tablet,
            viewport: Viewport(width: 1032, height: 1376, dpr: 2),
            shell: DeviceShell(top: 18, right: 18, bottom: 18, left: 18, radius: 35),
            safeArea: EdgeInsets(top: 24, right: 0, bottom: 20, left: 0),
            sensor: DeviceSensor(type: .punch, width: 8, height: 8, top: 5),
            safariChrome: false,
            homeIndicator: true,
            builtin: true
        ),
        DeviceProfile(
            id: "desktop-1440",
            name: "Desktop Safari · 1440",
            platform: .desktop,
            viewport: Viewport(width: 1440, height: 900, dpr: 1),
            shell: DeviceShell(top: 38, right: 5, bottom: 5, left: 5, radius: 13),
            safeArea: .zero,
            sensor: DeviceSensor(type: .none, width: 0, height: 0, top: 0),
            safariChrome: false,
            homeIndicator: false,
            builtin: true
        )
    ]

    static var customTemplate: DeviceProfile {
        DeviceProfile(
            id: UUID().uuidString,
            name: "Custom phone",
            platform: .custom,
            viewport: Viewport(width: 390, height: 844, dpr: 3),
            shell: DeviceShell(top: 10, right: 10, bottom: 10, left: 10, radius: 48),
            safeArea: EdgeInsets(top: 47, right: 0, bottom: 34, left: 0),
            sensor: DeviceSensor(type: .island, width: 118, height: 34, top: 10),
            safariChrome: false,
            homeIndicator: true,
            builtin: false
        )
    }
}

enum SafeAreaGeometry {
    static func oriented(_ insets: EdgeInsets, landscape: Bool) -> EdgeInsets {
        guard landscape else { return insets }
        return EdgeInsets(
            top: insets.right,
            right: insets.bottom,
            bottom: insets.left,
            left: insets.top
        )
    }

    static func pageInsets(_ insets: EdgeInsets, landscape: Bool, safariChrome: Bool) -> EdgeInsets {
        guard !safariChrome else { return .zero }
        return oriented(insets, landscape: landscape)
    }
}

enum SensorGeometry {
    static func frame(sensor: DeviceSensor, viewportFrame: CGRect, landscape: Bool) -> CGRect {
        guard landscape else {
            return CGRect(
                x: viewportFrame.minX + (viewportFrame.width - sensor.width) / 2,
                y: viewportFrame.minY + sensor.top,
                width: sensor.width,
                height: sensor.height
            )
        }

        // The rotate control presents the portrait top edge on the landscape
        // left, with the sensor centered vertically along that edge.
        return CGRect(
            x: viewportFrame.minX + sensor.top,
            y: viewportFrame.minY + (viewportFrame.height - sensor.width) / 2,
            width: sensor.height,
            height: sensor.width
        )
    }
}

enum HomeIndicatorGeometry {
    static func frame(viewportFrame: CGRect, landscape: Bool) -> CGRect {
        guard landscape else {
            return CGRect(
                x: viewportFrame.minX + (viewportFrame.width - 104) / 2,
                y: viewportFrame.maxY - 9,
                width: 104,
                height: 4
            )
        }

        // The portrait bottom edge becomes the landscape right edge.
        return CGRect(
            x: viewportFrame.maxX - 9,
            y: viewportFrame.minY + (viewportFrame.height - 104) / 2,
            width: 4,
            height: 104
        )
    }
}

struct SafariChromeMetrics {
    static let portraitTop: CGFloat = 112
    static let portraitBottom: CGFloat = 78
    static let landscapeTop: CGFloat = 72
    static let landscapeBottom: CGFloat = 52

    // AppKit can expose the viewport background between separately rendered
    // web and chrome surfaces when the device preview is fractionally scaled.
    // Keep this paint-only overlap large enough to cover the resampling seam.
    static let contentSeamOverlap: CGFloat = 4

    static func bottomFrame(viewportSize: CGSize, chromeHeight: CGFloat) -> CGRect {
        let overlap = chromeHeight > 0 ? min(contentSeamOverlap, chromeHeight) : 0
        return CGRect(
            x: 0,
            y: viewportSize.height - chromeHeight - overlap,
            width: viewportSize.width,
            height: chromeHeight + overlap
        )
    }
}

enum PreviewMetrics {
    static func appStatusBarHeight(device: DeviceProfile, landscape: Bool) -> CGFloat {
        guard device.platform == .iOS, !device.safariChrome, !landscape else { return 0 }
        return device.safeArea.top
    }

    static func headerTopInset(
        device: DeviceProfile,
        landscape: Bool,
        headerHeight: CGFloat
    ) -> CGFloat {
        guard headerHeight > 0 else { return 0 }
        return appStatusBarHeight(device: device, landscape: landscape)
    }

    static func contentSize(
        device: DeviceProfile,
        landscape: Bool,
        headerHeight: CGFloat,
        footerHeight: CGFloat,
        leftWidth: CGFloat = 0,
        rightWidth: CGFloat = 0
    ) -> CGSize {
        let width = landscape ? device.viewport.height : device.viewport.width
        let height = landscape ? device.viewport.width : device.viewport.height
        let sideWidths = sideLayerWidths(
            viewportWidth: width,
            landscape: landscape,
            leftWidth: leftWidth,
            rightWidth: rightWidth
        )
        let safariTop = device.safariChrome ? (landscape ? SafariChromeMetrics.landscapeTop : SafariChromeMetrics.portraitTop) : 0
        let safariBottom = device.safariChrome ? (landscape ? SafariChromeMetrics.landscapeBottom : SafariChromeMetrics.portraitBottom) : 0
        let headerTopInset = headerTopInset(
            device: device,
            landscape: landscape,
            headerHeight: headerHeight
        )
        return CGSize(
            width: max(1, width - sideWidths.left - sideWidths.right),
            height: max(1, height - safariTop - safariBottom - headerTopInset - headerHeight - footerHeight)
        )
    }

    static func sideLayerWidths(
        viewportWidth: CGFloat,
        landscape: Bool,
        leftWidth: CGFloat,
        rightWidth: CGFloat
    ) -> (left: CGFloat, right: CGFloat) {
        guard landscape else { return (0, 0) }
        let resolvedLeft = min(max(0, leftWidth), max(0, viewportWidth - 1))
        let resolvedRight = min(max(0, rightWidth), max(0, viewportWidth - resolvedLeft - 1))
        return (resolvedLeft, resolvedRight)
    }
}

enum DeviceStore {
    private static let key = "viewdeck.native.custom-devices"
    private static let defaults = UserDefaults(suiteName: "studio.viewdeck.native") ?? .standard

    static func load() -> [DeviceProfile] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DeviceProfile].self, from: data)) ?? []
    }

    static func save(_ devices: [DeviceProfile]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: key)
    }
}

enum HTMLLayerKind: String, Codable, CaseIterable {
    case header
    case footer
    case left
    case right

    var isSide: Bool {
        self == .left || self == .right
    }

    var reservedDimension: String {
        isSide ? "width" : "height"
    }

    var defaultExtent: CGFloat {
        switch self {
        case .header: 48
        case .footer: 56
        case .left, .right: 118
        }
    }
}

struct HTMLLayerReference: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var path: String
    var kind: HTMLLayerKind

    var url: URL { URL(fileURLWithPath: path) }
}

enum HTMLLayerStore {
    private static let key = "viewdeck.native.html-layer-library"
    private static let defaults = UserDefaults(suiteName: "studio.viewdeck.native") ?? .standard
    private static let bundledLayerRenames = [
        "sample-game-header": "h5_header",
        "minimal-footer": "h5_footer",
        "landscape-left-rail": "h5_left",
        "landscape-right-rail": "h5_right"
    ]

    static func load() -> [HTMLLayerReference] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoded = (try? JSONDecoder().decode([HTMLLayerReference].self, from: data)) ?? []
        let migrated = decoded.map(migrateBundledLayerReference)
        if migrated != decoded { save(migrated) }
        return migrated
    }

    static func save(_ layers: [HTMLLayerReference]) {
        guard let data = try? JSONEncoder().encode(layers) else { return }
        defaults.set(data, forKey: key)
    }

    private static func migrateBundledLayerReference(
        _ reference: HTMLLayerReference
    ) -> HTMLLayerReference {
        var migrated = reference
        let oldBase = reference.url.deletingPathExtension().lastPathComponent
        guard let newBase = bundledLayerRenames[oldBase]
            ?? bundledLayerRenames[reference.name] else { return reference }

        migrated.name = newBase
        let replacementURL = reference.url
            .deletingLastPathComponent()
            .appendingPathComponent(newBase)
            .appendingPathExtension("html")
        if FileManager.default.fileExists(atPath: replacementURL.path) {
            migrated.path = replacementURL.path
        }
        return migrated
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

class PassthroughView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
