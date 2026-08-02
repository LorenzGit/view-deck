import AppKit
import Foundation
import Network
import WebKit

protocol DevicePreviewDelegate: AnyObject {
    func previewDidStartLoading()
    func previewDidFinishLoading(title: String?, url: URL?)
    func previewDidFail(_ message: String)
}

enum NetworkResourceStatus: String, Codable {
    case pending
    case complete
    case failed
}

struct NetworkResourceActivity: Codable, Equatable {
    var id: String
    var url: String
    var initiatorType: String
    var status: NetworkResourceStatus
    var startTimeMilliseconds: Double
    var durationMilliseconds: Double?
    var transferSizeBytes: Int?
    var encodedBodySizeBytes: Int?
    var decodedBodySizeBytes: Int?
    var responseStatus: Int?
    var fromCache: Bool
    var error: String?
}

struct NetworkActivitySnapshot: Codable, Equatable {
    var loading: Bool
    var progress: Double
    var pendingCount: Int
    var completedCount: Int
    var failedCount: Int
    var resources: [NetworkResourceActivity]

    static let empty = NetworkActivitySnapshot(
        loading: false,
        progress: 0,
        pendingCount: 0,
        completedCount: 0,
        failedCount: 0,
        resources: []
    )
}

private final class QAScriptMessageHandler: NSObject, WKScriptMessageHandler {
    var receiver: (([String: Any]) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        receiver?(body)
    }
}

enum PreviewNavigationPolicy {
    static func normalizedWebURL(from rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let candidate: String
        if value.contains("://") {
            candidate = value
        } else if value.hasPrefix("//") {
            candidate = "http:\(value)"
        } else {
            candidate = "http://\(value)"
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else { return nil }
        return components.url
    }

    static func shouldIgnoreFailure(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    static func isUnexpectedBlankCompletion(_ loadedURL: URL?, requestedURL: URL?) -> Bool {
        guard requestedURL != nil else { return false }
        return loadedURL?.scheme?.lowercased() == "about"
    }

    static func userMessage(for error: Error) -> String {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }

        switch URLError.Code(rawValue: error.code) {
        case .cannotFindHost: return "The server could not be found."
        case .cannotConnectToHost: return "The server refused the connection."
        case .notConnectedToInternet: return "The internet connection appears to be offline."
        case .timedOut: return "The request timed out."
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return "A secure connection could not be established."
        default: return error.localizedDescription
        }
    }

    static func shouldOpenInCurrentPreview(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "file": return true
        default: return false
        }
    }

    static func isLocalDevelopmentURL(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return isLoopbackHost(host)
    }

    static func request(for url: URL, bypassCache: Bool) -> URLRequest {
        URLRequest(
            url: url,
            cachePolicy: bypassCache ? .reloadIgnoringLocalCacheData : .reloadRevalidatingCacheData
        )
    }

    static func websiteDataRecord(_ displayName: String, matches url: URL) -> Bool {
        guard let host = url.host else { return false }
        return hostsShareWebsiteData(displayName, host)
    }

    static func websiteDataScopesMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.isFileURL || rhs.isFileURL {
            return lhs.isFileURL && rhs.isFileURL
        }
        guard let lhsHost = lhs.host, let rhsHost = rhs.host else { return false }
        return hostsShareWebsiteData(lhsHost, rhsHost)
    }

    private static func hostsShareWebsiteData(_ lhs: String, _ rhs: String) -> Bool {
        let lhsHost = normalizedHost(lhs)
        let rhsHost = normalizedHost(rhs)
        if lhsHost == rhsHost { return true }
        if isLoopbackHost(lhsHost) && isLoopbackHost(rhsHost) { return true }
        return lhsHost.hasSuffix(".\(rhsHost)") || rhsHost.hasSuffix(".\(lhsHost)")
    }

    private static func normalizedHost(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func isLoopbackHost(_ value: String) -> Bool {
        let host = normalizedHost(value)
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "::1"
            || host == "0.0.0.0"
            || host.hasPrefix("127.")
    }
}

final class DevicePreviewView: FlippedView, WKNavigationDelegate, WKUIDelegate {
    private struct AudioActivityInterval {
        let startMilliseconds: Int
        var endMilliseconds: Int?
    }

    private static let videoFrameCaptureQueue = DispatchQueue(
        label: "studio.viewdeck.video-frame-capture",
        qos: .userInitiated
    )

    private static let mobileTrailingOverscan: CGFloat = 4
    private static let mobileBottomOverscan: CGFloat = 4
    private static let audioMonitorInterval: TimeInterval = 0.02
    private static let audioMutedFlag: UInt = 1
    private static let primaryWebsiteDataStoreIdentifier = UUID(
        uuidString: "2A94A7F7-99C0-4DCE-B61A-1422C18591C2"
    )!

    private static func enableDeveloperTools(in configuration: WKWebViewConfiguration) {
        // WebKit does not expose a public API for opening Web Inspector from a
        // macOS WKWebView. Keep its developer extras enabled for the private
        // inspector bridge used by ViewDeck's local development builds.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    }

    weak var delegate: DevicePreviewDelegate?
    var qaInputHandler: (([String: Any]) -> Void)?

    var profile: DeviceProfile {
        didSet {
            safeArea = profile.safeArea
            rebuildEnvironment(reload: currentURL != nil)
            needsLayout = true
            canvas?.needsLayout = true
        }
    }
    var landscape = false {
        didSet {
            safeOverlay.insets = webContentSafeArea
            updateNativePageInsets()
            needsLayout = true
            canvas?.needsLayout = true
            guard oldValue != landscape else { return }
            rebuildEnvironment(reload: false, updateUserAgent: false)
            schedulePageEnvironmentUpdate(orientationChanged: true)
        }
    }
    var safeArea: EdgeInsets {
        didSet {
            safeOverlay.insets = webContentSafeArea
            updateNativePageInsets()
            rebuildEnvironment(reload: currentURL != nil)
        }
    }
    var showSafeArea = false {
        didSet { safeOverlay.isHidden = !showSafeArea }
    }
    var applySafeAreaToPage = false {
        didSet {
            updateNativePageInsets()
            rebuildEnvironment(reload: currentURL != nil)
        }
    }
    var headerHTML: String? {
        didSet {
            let activationChanged = (oldValue == nil) != (headerHTML == nil)
            updateLayerWebViews()
            pageLayerGeometryDidChange()
            if activationChanged {
                rebuildEnvironment(reload: currentURL != nil)
            }
        }
    }
    var headerBaseURL: URL? {
        didSet { if headerHTML != nil { updateLayerWebViews() } }
    }
    var footerHTML: String? {
        didSet {
            updateLayerWebViews()
            pageLayerGeometryDidChange()
        }
    }
    var footerBaseURL: URL? {
        didSet { if footerHTML != nil { updateLayerWebViews() } }
    }
    var headerHeight: CGFloat = 48 {
        didSet { pageLayerGeometryDidChange() }
    }
    var footerHeight: CGFloat = 56 {
        didSet { pageLayerGeometryDidChange() }
    }
    var leftHTML: String? {
        didSet {
            updateLayerWebViews()
            pageLayerGeometryDidChange()
        }
    }
    var leftBaseURL: URL? {
        didSet { if leftHTML != nil { updateLayerWebViews() } }
    }
    var rightHTML: String? {
        didSet {
            updateLayerWebViews()
            pageLayerGeometryDidChange()
        }
    }
    var rightBaseURL: URL? {
        didSet { if rightHTML != nil { updateLayerWebViews() } }
    }
    var leftWidth: CGFloat = 118 {
        didSet { pageLayerGeometryDidChange() }
    }
    var rightWidth: CGFloat = 118 {
        didSet { pageLayerGeometryDidChange() }
    }

    private(set) var currentURL: URL?
    private weak var canvas: PreviewCanvasView?
    private let shellClip = FlippedView()
    private let viewportClip = FlippedView()
    private let safariTop = SafariTopView()
    private let safariBottom = SafariBottomView()
    private let appStatusBar = AppStatusBarView()
    private let safeOverlay = SafeAreaOverlayView()
    private let sensorView = FlippedView()
    private let homeIndicator = FlippedView()
    private let qaScriptMessageHandler: QAScriptMessageHandler
    private let webView: WKWebView
    private var headerWebView: WKWebView?
    private var footerWebView: WKWebView?
    private var leftWebView: WKWebView?
    private var rightWebView: WKWebView?
    private var navigationGeneration = 0
    private var environmentUpdateGeneration = 0
    private var silentAudioVerificationEnabled = false
    private var audioActivitySupported = false
    private var audioMonitorTimer: Timer?
    private var audioMonitoringStartedAt: Date?
    private var audioMonitoringStartedUptime: TimeInterval?
    private var audioActivityIntervals: [AudioActivityInterval] = []
    private(set) var offscreenRenderingEnabled = false
    private var networkProxy: NetworkShapingProxy?
    private var networkBridgeSourceURL: URL?
    private var networkBridgeURL: URL?
    private(set) var networkShapingConfiguration: NetworkShapingConfiguration
    private(set) var networkShapingSetupError: Error?

    init(
        profile: DeviceProfile,
        networkShapingConfiguration: NetworkShapingConfiguration = .disabled
    ) {
        self.profile = profile
        self.safeArea = profile.safeArea
        self.networkShapingConfiguration = networkShapingConfiguration.normalized

        let configuration = WKWebViewConfiguration()
        let qaScriptMessageHandler = QAScriptMessageHandler()
        self.qaScriptMessageHandler = qaScriptMessageHandler
        let websiteDataStore = WKWebsiteDataStore(
            forIdentifier: Self.primaryWebsiteDataStoreIdentifier
        )
        if networkShapingConfiguration.enabled {
            let proxy = NetworkShapingProxy(configuration: networkShapingConfiguration)
            do {
                let port = try proxy.start()
                websiteDataStore.proxyConfigurations = [Self.webKitProxyConfiguration(port: port)]
                networkProxy = proxy
            } catch {
                websiteDataStore.proxyConfigurations = []
                networkShapingSetupError = error
            }
        } else {
            websiteDataStore.proxyConfigurations = []
        }
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.add(qaScriptMessageHandler, name: "viewdeckQA")
        Self.enableDeveloperTools(in: configuration)
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: .zero)
        qaScriptMessageHandler.receiver = { [weak self] message in
            self?.qaInputHandler?(message)
        }
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x111419).cgColor
        layer?.borderColor = NSColor(hex: 0x6e7680).cgColor
        layer?.borderWidth = 1.25
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.72
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -8)

        shellClip.wantsLayer = true
        shellClip.layer?.masksToBounds = true
        addSubview(shellClip)

        viewportClip.wantsLayer = true
        viewportClip.layer?.masksToBounds = true
        viewportClip.layer?.backgroundColor = NSColor.black.cgColor
        viewportClip.layer?.borderColor = NSColor.black.withAlphaComponent(0.8).cgColor
        viewportClip.layer?.borderWidth = 0
        shellClip.addSubview(viewportClip)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.customUserAgent = profile.userAgent
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        viewportClip.addSubview(webView)
        viewportClip.addSubview(safariTop)
        viewportClip.addSubview(safariBottom)
        viewportClip.addSubview(appStatusBar)
        viewportClip.addSubview(safeOverlay)

        sensorView.wantsLayer = true
        sensorView.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(sensorView)

        homeIndicator.wantsLayer = true
        homeIndicator.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        addSubview(homeIndicator)

        safeOverlay.insets = webContentSafeArea
        safeOverlay.isHidden = !showSafeArea
        updateNativePageInsets()
        loadPlaceholder()
        rebuildEnvironment(reload: false)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        audioMonitorTimer?.invalidate()
        if networkProxy != nil {
            webView.configuration.websiteDataStore.proxyConfigurations = []
        }
        networkProxy?.stop()
    }

    @discardableResult
    func enableOffscreenRendering() -> Bool {
        let enabled = allWebViews
            .map { Self.setWindowOcclusionDetectionEnabled(false, in: $0) }
            .allSatisfy { $0 }
        offscreenRenderingEnabled = enabled
        return enabled
    }

    @discardableResult
    func applyNetworkShapingConfiguration(
        _ requestedConfiguration: NetworkShapingConfiguration,
        reloadIfNeeded: Bool = true
    ) -> Result<Void, Error> {
        let configuration = requestedConfiguration.normalized
        let previous = networkShapingConfiguration
        let dataStore = webView.configuration.websiteDataStore
        networkShapingSetupError = nil

        if configuration.enabled {
            if let networkProxy {
                networkProxy.update(configuration: configuration)
            } else {
                let proxy = NetworkShapingProxy(configuration: configuration)
                do {
                    let port = try proxy.start()
                    dataStore.proxyConfigurations = [Self.webKitProxyConfiguration(port: port)]
                    networkProxy = proxy
                } catch {
                    networkShapingSetupError = error
                    networkShapingConfiguration = previous
                    return .failure(error)
                }
            }
        } else {
            dataStore.proxyConfigurations = []
            networkProxy?.stop()
            networkProxy = nil
        }

        networkShapingConfiguration = configuration
        if reloadIfNeeded,
           let currentURL,
           (previous.enabled != configuration.enabled || previous.offline != configuration.offline) {
            load(currentURL.absoluteString, bypassCache: true, resetSiteData: false)
        }
        return .success(())
    }

    var networkShapingStatus: String {
        if let networkShapingSetupError {
            return networkShapingSetupError.localizedDescription
        }
        guard networkShapingConfiguration.enabled else { return "Disabled" }
        if networkShapingConfiguration.offline { return "Offline · connections blocked" }
        let report = networkProxy?.report(configuration: networkShapingConfiguration)
        guard networkProxy?.port != nil else { return "Starting…" }
        return report?["trafficObserved"] as? Bool == true
            ? "Verified · shaped TCP traffic observed"
            : "Ready · no shaped traffic observed yet"
    }

    func networkShapingReport() -> [String: Any] {
        if let networkProxy {
            var report = networkProxy.report(configuration: networkShapingConfiguration)
            if let source = networkBridgeSourceURL, let bridge = networkBridgeURL {
                report["localOriginRemapped"] = true
                report["requestedURL"] = source.absoluteString
                report["transportURL"] = bridge.absoluteString
            } else {
                report["localOriginRemapped"] = false
            }
            return report
        }
        var report = networkShapingConfiguration.reportDictionary
        report["implementation"] = "none"
        report["proxyPort"] = 0
        report["acceptedConnectionCount"] = 0
        report["activeConnectionCount"] = 0
        report["uploadedBytes"] = 0
        report["downloadedBytes"] = 0
        report["trafficObserved"] = false
        report["transportScope"] = "TCP traffic from the primary WKWebView"
        report["http3QUICShaped"] = false
        report["localOriginRemapped"] = false
        if let networkShapingSetupError {
            report["setupError"] = networkShapingSetupError.localizedDescription
        }
        return report
    }

    private static func webKitProxyConfiguration(port: NWEndpoint.Port) -> ProxyConfiguration {
        var configuration = ProxyConfiguration(
            socksv5Proxy: .hostPort(host: "127.0.0.1", port: port)
        )
        configuration.allowFailover = false
        // WebKit bypasses literal loopback destinations; shapedURL(for:) routes
        // local HTTP previews through a raw TCP bridge instead.
        configuration.matchDomains = [""]
        configuration.excludedDomains = []
        return configuration
    }

    var logicalViewportSize: CGSize {
        landscape
            ? CGSize(width: profile.viewport.height, height: profile.viewport.width)
            : CGSize(width: profile.viewport.width, height: profile.viewport.height)
    }

    var logicalSize: CGSize {
        let viewport = logicalViewportSize
        return CGSize(
            width: viewport.width + profile.shell.left + profile.shell.right,
            height: viewport.height + profile.shell.top + profile.shell.bottom
        )
    }

    var contentViewportSize: CGSize {
        PreviewMetrics.contentSize(
            device: profile,
            landscape: landscape,
            headerHeight: headerHTML == nil ? 0 : headerHeight,
            footerHeight: footerHTML == nil ? 0 : footerHeight,
            leftWidth: leftHTML == nil ? 0 : leftWidth,
            rightWidth: rightHTML == nil ? 0 : rightWidth
        )
    }

    private var appStatusBarHeight: CGFloat {
        PreviewMetrics.appStatusBarHeight(device: profile, landscape: landscape)
    }

    private var webContentSafeArea: EdgeInsets {
        let activeHeaderHeight = headerHTML == nil ? 0 : headerHeight
        let sideWidths = PreviewMetrics.sideLayerWidths(
            viewportWidth: logicalViewportSize.width,
            landscape: landscape,
            leftWidth: leftHTML == nil ? 0 : leftWidth,
            rightWidth: rightHTML == nil ? 0 : rightWidth
        )
        return SafeAreaGeometry.pageInsets(
            safeArea,
            landscape: landscape,
            safariChrome: profile.safariChrome,
            topReservedHeight: PreviewMetrics.headerReservedHeight(
                device: profile,
                landscape: landscape,
                headerHeight: activeHeaderHeight
            ),
            leftReservedWidth: sideWidths.left,
            rightReservedWidth: sideWidths.right
        )
    }

    private func pageLayerGeometryDidChange() {
        safeOverlay.insets = webContentSafeArea
        updateNativePageInsets()
        needsLayout = true
        schedulePageEnvironmentUpdate(orientationChanged: false)
    }

    func attach(to canvas: PreviewCanvasView) {
        self.canvas = canvas
    }

    func load(_ rawValue: String) {
        load(rawValue, bypassCache: false, resetSiteData: false)
    }

    func loadResettingSiteData(_ rawValue: String) {
        load(rawValue, bypassCache: true, resetSiteData: true)
    }

    func loadLocalServer(_ rawValue: String, resetSiteData: Bool) {
        load(rawValue, bypassCache: true, resetSiteData: resetSiteData)
    }

    func reloadResettingSiteData() {
        guard let currentURL else { return }
        if currentURL.isFileURL {
            loadLocalFile(currentURL, resetSiteData: true)
        } else {
            load(currentURL.absoluteString, bypassCache: true, resetSiteData: true)
        }
    }

    func prepareForLocalServerLaunch() {
        navigationGeneration &+= 1
        currentURL = nil
        webView.stopLoading()
        safariTop.address = "localhost"
        loadPlaceholder(
            title: "Starting local preview",
            message: "Waiting for the new server to become ready."
        )
    }

    private func load(_ rawValue: String, bypassCache: Bool, resetSiteData: Bool) {
        guard let url = PreviewNavigationPolicy.normalizedWebURL(from: rawValue) else {
            showNavigationFailure(
                message: "Enter a valid HTTP or HTTPS address.",
                reportMessage: "Invalid URL: \(rawValue)"
            )
            return
        }
        let requestURL: URL
        do {
            requestURL = try networkProxy?.shapedURL(for: url) ?? url
        } catch {
            networkShapingSetupError = error
            showNavigationFailure(
                message: "The local network shaping bridge could not start.",
                reportMessage: error.localizedDescription
            )
            return
        }
        if requestURL == url {
            networkBridgeSourceURL = nil
            networkBridgeURL = nil
        } else {
            networkBridgeSourceURL = url
            networkBridgeURL = requestURL
        }

        navigationGeneration &+= 1
        let generation = navigationGeneration
        safariTop.address = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        let request = PreviewNavigationPolicy.request(for: requestURL, bypassCache: bypassCache)
        let performLoad = { [weak self] in
            guard let self,
                  self.navigationGeneration == generation else { return }
            self.currentURL = url
            self.rebuildEnvironment(reload: false)
            self.webView.load(request)
        }
        if resetSiteData {
            clearWebsiteData(for: requestURL, completion: performLoad)
        } else {
            performLoad()
        }
    }

    private func displayURL(for loadedURL: URL) -> URL {
        guard let source = networkBridgeSourceURL,
              let bridge = networkBridgeURL,
              loadedURL.scheme?.lowercased() == bridge.scheme?.lowercased(),
              loadedURL.host?.lowercased() == bridge.host?.lowercased(),
              loadedURL.port == bridge.port,
              var components = URLComponents(url: loadedURL, resolvingAgainstBaseURL: false) else {
            return loadedURL
        }
        components.host = source.host
        components.port = source.port
        return components.url ?? loadedURL
    }

    private func displayNetworkURLs(in snapshot: [String: Any]) -> [String: Any] {
        var mapped = snapshot
        guard let resources = snapshot["resources"] as? [[String: Any]] else { return mapped }
        mapped["resources"] = resources.map { resource in
            var resource = resource
            if let rawURL = resource["url"] as? String,
               let url = URL(string: rawURL) {
                resource["url"] = displayURL(for: url).absoluteString
            }
            return resource
        }
        return mapped
    }

    func loadLocalFile(_ file: URL, resetSiteData: Bool = false) {
        navigationGeneration &+= 1
        let generation = navigationGeneration
        safariTop.address = file.lastPathComponent
        let performLoad = { [weak self] in
            guard let self, self.navigationGeneration == generation else { return }
            self.currentURL = file
            self.rebuildEnvironment(reload: false)
            self.webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        }
        if resetSiteData {
            clearWebsiteData(for: file, completion: performLoad)
        } else {
            performLoad()
        }
    }

    func reload() {
        rebuildEnvironment(reload: false)
        webView.reload()
    }

    func reloadFromOrigin() {
        guard let currentURL else { return }
        load(currentURL.absoluteString, bypassCache: true, resetSiteData: false)
    }

    func showWebInspector() {
        let inspectorSelector = NSSelectorFromString("_inspector")
        let showSelector = NSSelectorFromString("show")
        guard webView.responds(to: inspectorSelector),
              let inspector = webView.perform(inspectorSelector)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: showSelector) else {
            NSSound.beep()
            return
        }
        _ = inspector.perform(showSelector)
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    func evaluateJavaScript(
        _ source: String,
        completion: @escaping (Result<Any?, Error>) -> Void
    ) {
        webView.evaluateJavaScript(source) { value, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(value))
            }
        }
    }

    @discardableResult
    func enableSilentAudioVerification() -> Bool {
        guard !silentAudioVerificationEnabled else { return true }
        guard Self.setPageAudioMuted(true, in: webView),
              Self.isPageAudioMuted(in: webView) else { return false }

        silentAudioVerificationEnabled = true
        audioActivitySupported = Self.supportsAudioActivity(in: webView)
        audioMonitoringStartedAt = Date()
        audioMonitoringStartedUptime = ProcessInfo.processInfo.systemUptime
        audioActivityIntervals = []
        rebuildEnvironment(reload: false)
        applyAudioMuteToEveryWebView()
        sampleAudioActivity()

        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.audioMonitorInterval,
            repeats: true
        ) { [weak self] _ in
            self?.sampleAudioActivity()
        }
        timer.tolerance = Self.audioMonitorInterval / 4
        audioMonitorTimer = timer
        return true
    }

    func silentAudioVerificationReport() -> [String: Any] {
        sampleAudioActivity()
        let now = ProcessInfo.processInfo.systemUptime
        let muteApplied = allWebViews.allSatisfy(Self.isPageAudioMuted)
        let intervals = audioActivityIntervals.map { interval -> [String: Any] in
            let end = interval.endMilliseconds ?? elapsedAudioMilliseconds(at: now)
            return [
                "startMilliseconds": interval.startMilliseconds,
                "endMilliseconds": end,
                "durationMilliseconds": max(0, end - interval.startMilliseconds)
            ]
        }
        return [
            "mode": "verify-silent",
            "output": muteApplied ? "muted" : "unverified",
            "muteApplied": muteApplied,
            "muteBackend": "webkitPageMutedSPI",
            "activityBackend": "webkitPlayingAudioSPI",
            "activitySampleIntervalMilliseconds": Int(Self.audioMonitorInterval * 1_000),
            "activityMonitoringSupported": audioActivitySupported,
            "monitoringStartedAt": audioMonitoringStartedAt.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? "",
            "everActive": !intervals.isEmpty,
            "currentlyActive": audioActivityIntervals.last.map {
                $0.endMilliseconds == nil
            } ?? false,
            "activeIntervals": intervals
        ]
    }

    func captureAudit(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        evaluateJavaScript(Self.auditScript) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let value):
                guard let encoded = value as? String,
                      let data = encoded.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(PreviewInspectionError.invalidResult))
                    return
                }
                var report = object
                if let rawURL = report["url"] as? String,
                   let url = URL(string: rawURL) {
                    report["url"] = self.displayURL(for: url).absoluteString
                }
                if let network = report["network"] as? [String: Any] {
                    report["network"] = self.displayNetworkURLs(in: network)
                }
                completion(.success(report))
            }
        }
    }

    func captureNetworkActivity(
        completion: @escaping (Result<NetworkActivitySnapshot, Error>) -> Void
    ) {
        evaluateJavaScript(
            "JSON.stringify(window.__VIEWDECK_DIAGNOSTICS__?.network?.snapshot?.() ?? null)"
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let value):
                guard let encoded = value as? String,
                      encoded != "null",
                      let data = encoded.data(using: .utf8),
                      var snapshot = try? JSONDecoder().decode(
                        NetworkActivitySnapshot.self,
                        from: data
                      ) else {
                    completion(.success(.empty))
                    return
                }
                snapshot.resources = snapshot.resources.map { resource in
                    guard let url = URL(string: resource.url) else { return resource }
                    var mapped = resource
                    mapped.url = self.displayURL(for: url).absoluteString
                    return mapped
                }
                completion(.success(snapshot))
            }
        }
    }

    func captureNetworkActivitySignature(
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        evaluateJavaScript(
            "window.__VIEWDECK_DIAGNOSTICS__?.network?.signature?.() ?? ''"
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let value):
                completion(.success(value as? String ?? ""))
            }
        }
    }

    func beginQARecording() {
        evaluateJavaScript("window.__VIEWDECK_QA__?.start()") { _ in }
    }

    func endQARecording() {
        evaluateJavaScript("window.__VIEWDECK_QA__?.stop()") { _ in }
    }

    func replayQAEvent(
        _ event: QAInputEvent,
        completion: @escaping (Result<Any?, Error>) -> Void
    ) {
        do {
            let data = try JSONEncoder().encode(event)
            guard let json = String(data: data, encoding: .utf8) else {
                completion(.failure(PreviewInspectionError.invalidResult))
                return
            }
            evaluateJavaScript("window.__VIEWDECK_QA__?.replay(\(json))", completion: completion)
        } catch {
            completion(.failure(error))
        }
    }

    func captureQARuntimeEnvironment(
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        evaluateJavaScript(Self.qaRuntimeEnvironmentScript) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let value):
                guard let encoded = value as? String,
                      let data = encoded.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(PreviewInspectionError.invalidResult))
                    return
                }
                completion(.success(object))
            }
        }
    }

    func captureVideoFrame(
        scale requestedScale: CGFloat = 1,
        completion: @escaping (Result<NSImage, Error>) -> Void
    ) {
        layoutSubtreeIfNeeded()
        let captureBounds = viewportClip.bounds
        let captureScale = min(3, max(0.5, requestedScale))
        guard captureBounds.width > 0,
              captureBounds.height > 0,
              let window,
              window.windowNumber > 0 else {
            completion(.failure(PreviewScreenshotError.windowCompositorUnavailable))
            return
        }

        let frameInWindow = viewportClip.convert(captureBounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)
        let windowFrame = window.frame
        guard windowFrame.width > 0, windowFrame.height > 0 else {
            completion(.failure(PreviewScreenshotError.windowCompositorUnavailable))
            return
        }
        let windowNumber = CGWindowID(window.windowNumber)
        let targetWidth = Int((captureBounds.width * captureScale).rounded())
        let targetHeight = Int((captureBounds.height * captureScale).rounded())
        let resolution: CGWindowImageOption = captureScale <= 1 ? .nominalResolution : .bestResolution

        Self.videoFrameCaptureQueue.async {
            let options: CGWindowImageOption = [.boundsIgnoreFraming, resolution]
            guard let windowImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowNumber,
                options
            ) else {
                DispatchQueue.main.async {
                    completion(.failure(PreviewScreenshotError.windowCompositorUnavailable))
                }
                return
            }

            let imageScaleX = CGFloat(windowImage.width) / windowFrame.width
            let imageScaleY = CGFloat(windowImage.height) / windowFrame.height
            let requestedCrop = CGRect(
                x: (frameOnScreen.minX - windowFrame.minX) * imageScaleX,
                y: (windowFrame.maxY - frameOnScreen.maxY) * imageScaleY,
                width: frameOnScreen.width * imageScaleX,
                height: frameOnScreen.height * imageScaleY
            ).integral
            let imageBounds = CGRect(
                x: 0,
                y: 0,
                width: windowImage.width,
                height: windowImage.height
            )
            let crop = requestedCrop.intersection(imageBounds)
            guard crop.width > 1,
                  crop.height > 1,
                  let cropped = windowImage.cropping(to: crop),
                  let image = PreviewImageEncoding.image(
                      from: cropped,
                      pixelsWide: targetWidth,
                      pixelsHigh: targetHeight
                  ) else {
                DispatchQueue.main.async {
                    completion(.failure(PreviewScreenshotError.windowCompositorUnavailable))
                }
                return
            }
            DispatchQueue.main.async {
                completion(.success(image))
            }
        }
    }


    /// Export GPU canvas pixels via JS, inject as an <img> under the DOM, then WebKit-snapshot.
    /// Painting the readback in-page preserves HUD z-order (full-screen canvas overlays wiped it).
    func captureScreenshotWithCanvasReadback(
        scale requestedScale: CGFloat? = nil,
        completion: @escaping (Result<NSImage, Error>) -> Void
    ) {
        let captureScale = min(3, max(0.5, requestedScale ?? profile.viewport.dpr))
        evaluateJavaScript(Self.canvasInjectReadbackScript) { [weak self] injectResult in
            guard let self else { return }
            let injected: Bool = {
                guard case .success(let value) = injectResult,
                      let encoded = value as? String,
                      let data = encoded.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["ok"] as? Bool == true
                else { return false }
                return true
            }()

            self.captureScreenshot(scale: captureScale) { [weak self] snapResult in
                guard let self else { return }
                self.evaluateJavaScript(Self.canvasCleanupReadbackScript) { _ in
                    switch snapResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let image):
                        // If inject failed we still return the plain snapshot (DOM + blank GPU).
                        _ = injected
                        completion(.success(image))
                    }
                }
            }
        }
    }

    /// Read canvas (game hook → toDataURL → 2D drawImage), hide the live canvas, show a PNG <img>.
    private static let canvasInjectReadbackScript = """
    (async function () {
      try {
        document.getElementById('__viewdeck_canvas_capture')?.remove();
        const canvas = document.querySelector('canvas');
        if (!canvas) return JSON.stringify({ error: 'no-canvas', ok: false });
        const rect = canvas.getBoundingClientRect();
        let dataUrl = null;
        let source = null;
        if (typeof window.__viewdeckCaptureCanvas === 'function') {
          try {
            const result = window.__viewdeckCaptureCanvas();
            dataUrl = (result && typeof result.then === 'function') ? await result : result;
            if (dataUrl && typeof dataUrl === 'string' && dataUrl.length > 64) source = 'hook';
          } catch (e) {}
        }
        if (!dataUrl || typeof dataUrl !== 'string' || dataUrl.length < 64) {
          try {
            dataUrl = canvas.toDataURL('image/png');
            if (dataUrl && dataUrl.length > 64) source = 'toDataURL';
          } catch (e) {}
        }
        if (!dataUrl || typeof dataUrl !== 'string' || dataUrl.length < 64) {
          try {
            const c2 = document.createElement('canvas');
            c2.width = canvas.width || Math.max(1, Math.round(rect.width * (window.devicePixelRatio || 1)));
            c2.height = canvas.height || Math.max(1, Math.round(rect.height * (window.devicePixelRatio || 1)));
            const ctx = c2.getContext('2d');
            if (ctx) {
              ctx.drawImage(canvas, 0, 0);
              dataUrl = c2.toDataURL('image/png');
              if (dataUrl && dataUrl.length > 64) source = 'drawImage';
            }
          } catch (e) {}
        }
        if (!dataUrl || typeof dataUrl !== 'string' || dataUrl.length < 64) {
          return JSON.stringify({
            error: 'empty-canvas',
            ok: false,
            x: rect.x, y: rect.y, width: rect.width, height: rect.height
          });
        }
        const img = document.createElement('img');
        img.id = '__viewdeck_canvas_capture';
        img.alt = '';
        img.src = dataUrl;
        img.setAttribute('data-viewdeck-source', source || 'unknown');
        // Sit in the canvas parent so later DOM HUD siblings still paint on top.
        const parent = canvas.parentElement || document.body;
        const parentStyle = window.getComputedStyle(parent);
        if (parentStyle.position === 'static') {
          if (!parent.dataset.viewdeckPrevPosition) {
            parent.dataset.viewdeckPrevPosition = parent.style.position || '';
          }
          parent.style.position = 'relative';
        }
        // Full-bleed over the canvas host. Source PNG must share the canvas CSS
        // aspect (see game __viewdeckCaptureCanvas); fill then matches live layout.
        img.style.cssText = [
          'position:absolute',
          'left:0',
          'top:0',
          'width:100%',
          'height:100%',
          'margin:0',
          'padding:0',
          'border:0',
          'display:block',
          'pointer-events:none',
          'z-index:0',
          'object-fit:fill'
        ].join(';');
        if (!canvas.dataset.viewdeckPrevVisibility) {
          canvas.dataset.viewdeckPrevVisibility = canvas.style.visibility || '';
        }
        if (!canvas.dataset.viewdeckPrevPosition) {
          canvas.dataset.viewdeckPrevPosition = canvas.style.position || '';
        }
        canvas.style.visibility = 'hidden';
        canvas.style.position = canvas.style.position || 'absolute';
        parent.insertBefore(img, canvas);
        await new Promise(function (resolve) {
          if (img.complete) resolve();
          else { img.onload = function () { resolve(); }; img.onerror = function () { resolve(); }; }
        });
        return JSON.stringify({
          ok: true,
          source: source,
          x: rect.x,
          y: rect.y,
          width: rect.width,
          height: rect.height,
          dpr: window.devicePixelRatio || 1,
          bytes: dataUrl.length
        });
      } catch (e) {
        return JSON.stringify({ error: String(e), ok: false });
      }
    })()
    """

    private static let canvasCleanupReadbackScript = """
    (function () {
      document.getElementById('__viewdeck_canvas_capture')?.remove();
      document.querySelectorAll('canvas').forEach(function (canvas) {
        if (Object.prototype.hasOwnProperty.call(canvas.dataset, 'viewdeckPrevVisibility')) {
          canvas.style.visibility = canvas.dataset.viewdeckPrevVisibility;
          delete canvas.dataset.viewdeckPrevVisibility;
        }
        if (Object.prototype.hasOwnProperty.call(canvas.dataset, 'viewdeckPrevPosition')) {
          canvas.style.position = canvas.dataset.viewdeckPrevPosition;
          delete canvas.dataset.viewdeckPrevPosition;
        }
        const parent = canvas.parentElement;
        if (parent && Object.prototype.hasOwnProperty.call(parent.dataset, 'viewdeckPrevPosition')) {
          parent.style.position = parent.dataset.viewdeckPrevPosition;
          delete parent.dataset.viewdeckPrevPosition;
        }
      });
      return true;
    })()
    """

    func captureScreenshot(
        scale requestedScale: CGFloat? = nil,
        completion: @escaping (Result<NSImage, Error>) -> Void
    ) {
        layoutSubtreeIfNeeded()
        let captureBounds = viewportClip.bounds
        let captureScale = min(3, max(0.5, requestedScale ?? profile.viewport.dpr))
        guard captureBounds.width > 0,
              captureBounds.height > 0,
              let baseImage = SnapshotImageRenderer.image(
                of: viewportClip,
                rect: captureBounds,
                scale: captureScale
              ) else {
            completion(.failure(PreviewScreenshotError.renderFailed))
            return
        }

        let viewportFrame = captureBounds
        let sources = [leftWebView, headerWebView, webView, footerWebView, rightWebView].compactMap { $0 }
        guard !sources.isEmpty else {
            completion(.success(baseImage))
            return
        }

        var webLayers = Array<PreviewScreenshotLayer?>(repeating: nil, count: sources.count)
        let group = DispatchGroup()
        for (index, source) in sources.enumerated() {
            guard source.bounds.width > 0, source.bounds.height > 0 else { continue }
            group.enter()
            let configuration = WKSnapshotConfiguration()
            configuration.rect = source.bounds
            configuration.snapshotWidth = NSNumber(value: Double(source.bounds.width * captureScale))
            let frame = source.convert(source.bounds, to: viewportClip)
            source.takeSnapshot(with: configuration) { image, _ in
                if let image {
                    webLayers[index] = PreviewScreenshotLayer(
                        image: image,
                        frame: frame,
                        clipFrame: viewportFrame
                    )
                }
                group.leave()
            }
        }

        let nativeViews = [safariTop, safariBottom, appStatusBar, safeOverlay, sensorView, homeIndicator]
        let nativeLayers = nativeViews.compactMap { view -> PreviewScreenshotLayer? in
            guard !view.isHidden,
                  view.bounds.width > 0,
                  view.bounds.height > 0,
                  let image = SnapshotImageRenderer.image(of: view, rect: view.bounds, scale: captureScale) else {
                return nil
            }
            return PreviewScreenshotLayer(
                image: image,
                frame: view.convert(view.bounds, to: viewportClip),
                clipFrame: nil
            )
        }

        group.notify(queue: .main) {
            let compositor = PreviewScreenshotCompositor(
                size: captureBounds.size,
                baseImage: baseImage,
                webLayers: webLayers.compactMap { $0 },
                nativeLayers: nativeLayers
            )
            guard let image = SnapshotImageRenderer.image(
                of: compositor,
                rect: compositor.bounds,
                scale: captureScale
            ) else {
                completion(.failure(PreviewScreenshotError.renderFailed))
                return
            }
            completion(.success(image))
        }
    }

    override func layout() {
        super.layout()
        let size = logicalSize
        bounds = CGRect(origin: .zero, size: size)
        layer?.cornerRadius = profile.shell.radius
        shellClip.frame = bounds
        shellClip.bounds = bounds
        let shellBottomBleed: CGFloat = profile.shell.bottom == 0 ? 2 : 0
        if shellBottomBleed > 0 {
            shellClip.layer?.cornerRadius = 0
            let shellMask = CAShapeLayer()
            shellMask.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height + shellBottomBleed)
            shellMask.path = shellMaskPath(size: size, bottomBleed: shellBottomBleed)
            shellClip.layer?.mask = shellMask
        } else {
            shellClip.layer?.mask = nil
            shellClip.layer?.cornerRadius = profile.shell.radius
        }

        let viewportSize = logicalViewportSize
        let viewportFrame = CGRect(
            x: profile.shell.left,
            y: profile.shell.top,
            width: viewportSize.width,
            height: viewportSize.height
        )
        viewportClip.frame = viewportFrame
        viewportClip.bounds = CGRect(origin: .zero, size: viewportSize)
        let largestShellInset = max(profile.shell.top, profile.shell.right, profile.shell.bottom, profile.shell.left)
        let shellIsAsymmetric = profile.shell.bottom != profile.shell.top
            || profile.shell.left != profile.shell.top
            || profile.shell.right != profile.shell.top
        if shellIsAsymmetric {
            // Clip with the outer shell path translated into viewport coordinates so
            // every corner stays concentric with the frame; masksToBounds supplies the
            // intersection with the viewport rect.
            viewportClip.layer?.cornerRadius = 0
            let mask = CAShapeLayer()
            mask.frame = CGRect(
                x: -profile.shell.left,
                y: -profile.shell.top,
                width: size.width,
                height: size.height + shellBottomBleed
            )
            mask.path = shellMaskPath(size: size, bottomBleed: shellBottomBleed)
            viewportClip.layer?.mask = mask
        } else {
            viewportClip.layer?.mask = nil
            viewportClip.layer?.cornerRadius = max(0, profile.shell.radius - largestShellInset + 1)
        }
        let isModernIOSApp = profile.platform == .iOS && !profile.safariChrome && profile.sensor.type == .island
        viewportClip.layer?.borderWidth = isModernIOSApp ? 0 : 1

        let topChrome: CGFloat = profile.safariChrome
            ? (landscape ? SafariChromeMetrics.landscapeTop : SafariChromeMetrics.portraitTop)
            : 0
        let bottomChrome: CGFloat = profile.safariChrome
            ? (landscape ? SafariChromeMetrics.landscapeBottom : SafariChromeMetrics.portraitBottom)
            : 0
        let activeHeaderHeight = headerHTML == nil ? 0 : headerHeight
        let activeFooterHeight = footerHTML == nil ? 0 : footerHeight
        let sideWidths = PreviewMetrics.sideLayerWidths(
            viewportWidth: viewportSize.width,
            landscape: landscape,
            leftWidth: leftHTML == nil ? 0 : leftWidth,
            rightWidth: rightHTML == nil ? 0 : rightWidth
        )
        let contentX = sideWidths.left
        let contentWidth = max(1, viewportSize.width - sideWidths.left - sideWidths.right)
        let headerTopInset = PreviewMetrics.headerTopInset(
            device: profile,
            landscape: landscape,
            headerHeight: activeHeaderHeight
        )
        let pageHeight = max(
            1,
            viewportSize.height
                - topChrome
                - bottomChrome
                - headerTopInset
                - activeHeaderHeight
                - activeFooterHeight
        )

        safariTop.isHidden = !profile.safariChrome
        safariBottom.isHidden = !profile.safariChrome
        safariTop.compact = landscape
        safariBottom.compact = landscape
        safariTop.frame = CGRect(x: contentX, y: 0, width: contentWidth, height: topChrome)
        var safariBottomFrame = SafariChromeMetrics.bottomFrame(
            viewportSize: viewportSize,
            chromeHeight: bottomChrome
        )
        safariBottomFrame.origin.x = contentX
        safariBottomFrame.size.width = contentWidth
        safariBottom.frame = safariBottomFrame
        appStatusBar.isHidden = profile.platform != .iOS || profile.safariChrome || landscape
        appStatusBar.frame = CGRect(
            x: contentX,
            y: 0,
            width: contentWidth,
            height: appStatusBar.isHidden ? 0 : appStatusBarHeight
        )

        var pageY = topChrome + headerTopInset
        let trailingOverscan = profile.mobile ? Self.mobileTrailingOverscan : 0
        let bottomOverscan = isModernIOSApp ? Self.mobileBottomOverscan : 0
        if let leftWebView {
            leftWebView.isHidden = sideWidths.left == 0
            leftWebView.frame = CGRect(
                x: 0,
                y: 0,
                width: sideWidths.left,
                height: viewportSize.height + bottomOverscan
            )
        }
        if let rightWebView {
            rightWebView.isHidden = sideWidths.right == 0
            rightWebView.frame = CGRect(
                x: viewportSize.width - sideWidths.right,
                y: 0,
                width: sideWidths.right + trailingOverscan,
                height: viewportSize.height + bottomOverscan
            )
        }
        if let headerWebView {
            headerWebView.frame = CGRect(
                x: contentX,
                y: pageY,
                width: contentWidth + trailingOverscan,
                height: activeHeaderHeight
            )
            pageY += activeHeaderHeight
        }
        let pageFrame = CGRect(x: contentX, y: pageY, width: contentWidth, height: pageHeight)
        webView.frame = CGRect(
            x: pageFrame.minX,
            y: pageFrame.minY,
            width: pageFrame.width + trailingOverscan,
            height: pageFrame.height + (footerHTML == nil ? bottomOverscan : 0)
        )
        webView.bounds = CGRect(origin: .zero, size: webView.frame.size)
        updateNativePageInsets()
        let safeOverlayFrame = profile.safariChrome
            ? pageFrame
            : CGRect(x: contentX, y: 0, width: contentWidth, height: viewportSize.height)
        safeOverlay.frame = safeOverlayFrame
        safeOverlay.bounds = CGRect(origin: .zero, size: safeOverlayFrame.size)
        pageY += pageHeight
        if let footerWebView {
            footerWebView.frame = CGRect(
                x: contentX,
                y: pageY,
                width: contentWidth + trailingOverscan,
                height: activeFooterHeight + bottomOverscan
            )
        }

        let sensor = profile.sensor
        sensorView.isHidden = sensor.type == .none
        if !sensorView.isHidden {
            sensorView.frame = SensorGeometry.frame(
                sensor: sensor,
                viewportFrame: viewportFrame,
                landscape: landscape
            )
            sensorView.layer?.cornerRadius = min(sensorView.frame.width, sensorView.frame.height) / 2
        }

        homeIndicator.isHidden = !profile.homeIndicator || profile.safariChrome
        if !homeIndicator.isHidden {
            homeIndicator.frame = HomeIndicatorGeometry.frame(
                viewportFrame: viewportFrame,
                landscape: landscape
            )
            homeIndicator.layer?.cornerRadius = 2
        }

        viewportClip.addSubview(safariTop, positioned: .above, relativeTo: nil)
        viewportClip.addSubview(safariBottom, positioned: .above, relativeTo: nil)
        viewportClip.addSubview(appStatusBar, positioned: .above, relativeTo: nil)
        viewportClip.addSubview(safeOverlay, positioned: .above, relativeTo: nil)
        addSubview(sensorView, positioned: .above, relativeTo: nil)
        addSubview(homeIndicator, positioned: .above, relativeTo: nil)
    }

    private func shellMaskPath(size: CGSize, bottomBleed: CGFloat) -> CGPath {
        let radius = min(profile.shell.radius, size.width / 2, size.height / 2)
        let bottomEdge = size.height + bottomBleed
        let kappa: CGFloat = 0.552_284_75

        let path = CGMutablePath()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: size.width - radius, y: 0))
        path.addCurve(
            to: CGPoint(x: size.width, y: radius),
            control1: CGPoint(x: size.width - radius + radius * kappa, y: 0),
            control2: CGPoint(x: size.width, y: radius - radius * kappa)
        )
        path.addLine(to: CGPoint(x: size.width, y: size.height - radius))
        path.addCurve(
            to: CGPoint(x: size.width - radius, y: size.height),
            control1: CGPoint(x: size.width, y: size.height - radius + radius * kappa),
            control2: CGPoint(x: size.width - radius + radius * kappa, y: size.height)
        )
        path.addLine(to: CGPoint(x: size.width - radius, y: bottomEdge))
        path.addLine(to: CGPoint(x: radius, y: bottomEdge))
        path.addLine(to: CGPoint(x: radius, y: size.height))
        path.addCurve(
            to: CGPoint(x: 0, y: size.height - radius),
            control1: CGPoint(x: radius - radius * kappa, y: size.height),
            control2: CGPoint(x: 0, y: size.height - radius + radius * kappa)
        )
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addCurve(
            to: CGPoint(x: radius, y: 0),
            control1: CGPoint(x: 0, y: radius - radius * kappa),
            control2: CGPoint(x: radius - radius * kappa, y: 0)
        )
        path.closeSubpath()
        return path
    }

    private func loadPlaceholder(
        title: String = "Native WebKit preview",
        message: String = "Enter a URL or start a local project.",
        mark: String = "◇"
    ) {
        let safeTitle = htmlEscaped(title)
        let safeMessage = htmlEscaped(message)
        let safeMark = htmlEscaped(mark)
        let html = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{height:100%;margin:0;background:#0d1013;color:#89919a;font:15px -apple-system;display:grid;place-items:center;text-align:center}.box{max-width:280px;padding:24px}.mark{font-size:38px;color:#b9f45c}b{display:block;color:#e9edf0;font-size:18px;margin:10px}</style>
        <div class="box"><div class="mark">\(safeMark)</div><b>\(safeTitle)</b>\(safeMessage)</div>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func showNavigationFailure(message: String, reportMessage: String) {
        navigationGeneration &+= 1
        currentURL = nil
        webView.stopLoading()
        safariTop.address = "Unavailable"
        loadPlaceholder(title: "Unable to load page", message: message, mark: "!")
        delegate?.previewDidFail(reportMessage)
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func clearWebsiteData(for url: URL, completion: @escaping () -> Void) {
        let clearPersistentData = { [weak self] in
            self?.removeWebsiteDataRecord(for: url, completion: completion)
        }
        guard let currentURL,
              PreviewNavigationPolicy.websiteDataScopesMatch(currentURL, url) else {
            clearPersistentData()
            return
        }
        webView.evaluateJavaScript(Self.clearClientStorageScript) { _, _ in
            clearPersistentData()
        }
    }

    private func removeWebsiteDataRecord(for url: URL, completion: @escaping () -> Void) {
        guard url.host != nil else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        let dataStore = webView.configuration.websiteDataStore
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            let matchingRecords = records.filter {
                PreviewNavigationPolicy.websiteDataRecord($0.displayName, matches: url)
            }
            guard !matchingRecords.isEmpty else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            dataStore.removeData(ofTypes: dataTypes, for: matchingRecords) {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private static let clearClientStorageScript = """
    (() => {
      try { localStorage.clear(); } catch (_) {}
      try { sessionStorage.clear(); } catch (_) {}
      try {
        if (window.caches) {
          caches.keys().then(keys => Promise.all(keys.map(key => caches.delete(key))));
        }
      } catch (_) {}
      try {
        navigator.serviceWorker?.getRegistrations?.()
          .then(registrations => registrations.forEach(registration => registration.unregister()));
      } catch (_) {}
      try {
        indexedDB.databases?.().then(databases => {
          databases.forEach(database => {
            if (database.name) indexedDB.deleteDatabase(database.name);
          });
        });
      } catch (_) {}
      return true;
    })()
    """

    private func updateLayerWebViews() {
        if let headerHTML {
            if headerWebView == nil { headerWebView = makeLayerWebView() }
            headerWebView?.loadHTMLString(headerHTML, baseURL: headerBaseURL)
        } else {
            headerWebView?.removeFromSuperview()
            headerWebView = nil
        }
        if let footerHTML {
            if footerWebView == nil { footerWebView = makeLayerWebView() }
            footerWebView?.loadHTMLString(footerHTML, baseURL: footerBaseURL)
        } else {
            footerWebView?.removeFromSuperview()
            footerWebView = nil
        }
        if let leftHTML {
            if leftWebView == nil { leftWebView = makeLayerWebView() }
            leftWebView?.loadHTMLString(leftHTML, baseURL: leftBaseURL)
        } else {
            leftWebView?.removeFromSuperview()
            leftWebView = nil
        }
        if let rightHTML {
            if rightWebView == nil { rightWebView = makeLayerWebView() }
            rightWebView?.loadHTMLString(rightHTML, baseURL: rightBaseURL)
        } else {
            rightWebView?.removeFromSuperview()
            rightWebView = nil
        }
        needsLayout = true
        canvas?.needsLayout = true
    }

    private func makeLayerWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        Self.enableDeveloperTools(in: configuration)
        let layerView = WKWebView(frame: .zero, configuration: configuration)
        layerView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { layerView.isInspectable = true }
        if silentAudioVerificationEnabled {
            _ = Self.setPageAudioMuted(true, in: layerView)
        }
        if offscreenRenderingEnabled {
            _ = Self.setWindowOcclusionDetectionEnabled(false, in: layerView)
        }
        viewportClip.addSubview(layerView)
        return layerView
    }

    private func rebuildEnvironment(reload: Bool, updateUserAgent: Bool = true) {
        updateNativePageInsets()
        if updateUserAgent {
            webView.customUserAgent = profile.userAgent
        }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: Self.diagnosticsBootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        if silentAudioVerificationEnabled {
            controller.addUserScript(WKUserScript(
                source: Self.audioDiagnosticsBootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        controller.addUserScript(WKUserScript(
            source: Self.qaBootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: bootstrapScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        if reload, currentURL != nil { webView.reload() }
    }

    private var allWebViews: [WKWebView] {
        [webView, headerWebView, footerWebView, leftWebView, rightWebView].compactMap { $0 }
    }

    private func applyAudioMuteToEveryWebView() {
        for view in allWebViews {
            _ = Self.setPageAudioMuted(true, in: view)
        }
    }

    private func sampleAudioActivity() {
        guard silentAudioVerificationEnabled, audioActivitySupported else { return }
        let isActive = allWebViews.contains(where: Self.isPlayingAudio)
        let elapsed = elapsedAudioMilliseconds(at: ProcessInfo.processInfo.systemUptime)
        if isActive {
            if audioActivityIntervals.last?.endMilliseconds != nil || audioActivityIntervals.isEmpty {
                audioActivityIntervals.append(AudioActivityInterval(
                    startMilliseconds: elapsed,
                    endMilliseconds: nil
                ))
            }
        } else if !audioActivityIntervals.isEmpty,
                  audioActivityIntervals[audioActivityIntervals.count - 1].endMilliseconds == nil {
            audioActivityIntervals[audioActivityIntervals.count - 1].endMilliseconds = elapsed
        }
    }

    private func elapsedAudioMilliseconds(at uptime: TimeInterval) -> Int {
        guard let started = audioMonitoringStartedUptime else { return 0 }
        return max(0, Int((uptime - started) * 1_000))
    }

    private static func setPageAudioMuted(_ muted: Bool, in webView: WKWebView) -> Bool {
        // Public WKWebView media controls pause playback. Hidden QA runs need
        // WebKit's page mute so media timing continues while output is silent.
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        let setter = unsafeBitCast(webView.method(for: selector), to: Setter.self)
        setter(webView, selector, muted ? audioMutedFlag : 0)
        return true
    }

    private static func supportsAudioActivity(in webView: WKWebView) -> Bool {
        webView.responds(to: NSSelectorFromString("_isPlayingAudio"))
    }

    private static func isPageAudioMuted(in webView: WKWebView) -> Bool {
        let selector = NSSelectorFromString("_mediaMutedState")
        guard webView.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        let getter = unsafeBitCast(webView.method(for: selector), to: Getter.self)
        return getter(webView, selector) & audioMutedFlag != 0
    }

    private static func isPlayingAudio(in webView: WKWebView) -> Bool {
        let selector = NSSelectorFromString("_isPlayingAudio")
        guard webView.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(webView.method(for: selector), to: Getter.self)
        return getter(webView, selector)
    }

    private static func setWindowOcclusionDetectionEnabled(
        _ enabled: Bool,
        in webView: WKWebView
    ) -> Bool {
        let setterSelector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        let getterSelector = NSSelectorFromString("_windowOcclusionDetectionEnabled")
        guard webView.responds(to: setterSelector),
              webView.responds(to: getterSelector) else { return false }

        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let setter = unsafeBitCast(webView.method(for: setterSelector), to: Setter.self)
        let getter = unsafeBitCast(webView.method(for: getterSelector), to: Getter.self)
        setter(webView, setterSelector, enabled)
        return getter(webView, getterSelector) == enabled
    }

    private func schedulePageEnvironmentUpdate(orientationChanged: Bool) {
        guard currentURL != nil else { return }
        environmentUpdateGeneration &+= 1
        let generation = environmentUpdateGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.environmentUpdateGeneration == generation else { return }
            self.canvas?.layoutSubtreeIfNeeded()
            self.layoutSubtreeIfNeeded()
            self.webView.evaluateJavaScript(
                self.pageEnvironmentUpdateScript(orientationChanged: orientationChanged)
            )
        }
    }

    private func updateNativePageInsets() {
        guard #available(macOS 26.0, *) else { return }
        let safe = applySafeAreaToPage ? webContentSafeArea : .zero
        webView.obscuredContentInsets = NSEdgeInsets(
            top: safe.top,
            left: safe.left,
            bottom: safe.bottom,
            right: safe.right
        )
    }

    private func pageEnvironmentJSON() -> String {
        let viewport = contentViewportSize
        let screen = logicalViewportSize
        let platform = profile.platform == .iOS || profile.platform == .tablet
            ? "ios"
            : profile.platform == .android ? "android" : "web"
        let pageSafeArea = webContentSafeArea
        let device: [String: Any] = [
            "model": profile.name,
            "platform": platform,
            "pixelRatio": profile.viewport.dpr,
            "screenSize": ["width": screen.width, "height": screen.height],
            "viewportSize": ["width": viewport.width, "height": viewport.height]
        ]
        let environment: [String: Any] = [
            "platform": platform,
            "isMobile": profile.mobile,
            "browserInfo": ["browser": "safari", "engine": "webkit"],
            "input": [
                "primaryPointer": profile.mobile ? "coarse" : "fine",
                "anyPointers": [profile.mobile ? "coarse" : "fine"],
                "primaryHover": profile.mobile ? "none" : "hover",
                "anyHovers": [profile.mobile ? "none" : "hover"]
            ]
        ]
        let needsCSSPaddingFallback: Bool
        if #available(macOS 26.0, *) {
            needsCSSPaddingFallback = false
        } else {
            needsCSSPaddingFallback = applySafeAreaToPage
        }

        return json([
            "safeArea": [
                "top": pageSafeArea.top,
                "right": pageSafeArea.right,
                "bottom": pageSafeArea.bottom,
                "left": pageSafeArea.left
            ],
            "device": device,
            "environment": environment,
            "navigator": [
                "platform": platform == "ios" ? "iPhone" : platform == "android" ? "Linux armv8l" : "MacIntel",
                "maxTouchPoints": profile.mobile ? 5 : 0
            ],
            "landscape": landscape,
            "forcePageInsets": needsCSSPaddingFallback
        ])
    }

    private func pageEnvironmentUpdateScript(orientationChanged: Bool) -> String {
        """
        (() => {
          const apply = window.__VIEWDECK_APPLY_ENVIRONMENT__;
          if (typeof apply !== 'function') return;
          apply(\(pageEnvironmentJSON()), {
            notify: true,
            orientationChanged: \(orientationChanged ? "true" : "false")
          });
        })();
        """
    }

    private func bootstrapScript() -> String {
        let initialEnvironment = pageEnvironmentJSON()
        let headerManagesTopInset = headerHTML != nil ? "true" : "false"

        return """
        (() => {
          const initialEnvironment = \(initialEnvironment);
          const headerManagesTopInset = \(headerManagesTopInset);
          const runtime = window.__VIEWDECK_RUNTIME__ || {};
          window.__VIEWDECK_RUNTIME__ = runtime;

          // A native header makes the webview's zero top inset authoritative.
          // Preserve an embedded runtime's complete local implementation while
          // presenting the same non-mock layout semantics it exposes on-device.
          const installHeaderManagedRuntime = () => {
            if (!headerManagesTopInset || runtime.headerManagedRuntimeInstalled) return;
            runtime.headerManagedRuntimeInstalled = true;

            let embeddedAPI;
            const applyAuthoritativeInsets = (candidate) => {
              if (!candidate || (typeof candidate !== 'object' && typeof candidate !== 'function')) {
                return candidate;
              }
              try {
                Object.defineProperty(candidate, 'isMock', {
                  configurable: true,
                  enumerable: true,
                  get() {
                    return () => false;
                  },
                  set() {}
                });
              } catch {
                candidate.isMock = () => false;
              }
              return candidate;
            };

            const existingAPI = window.RundotGameAPI;
            try {
              Object.defineProperty(window, 'RundotGameAPI', {
                configurable: true,
                enumerable: true,
                get() {
                  return embeddedAPI;
                },
                set(value) {
                  embeddedAPI = applyAuthoritativeInsets(value);
                }
              });
              if (existingAPI) window.RundotGameAPI = existingAPI;
            } catch {
              applyAuthoritativeInsets(existingAPI);
            }
          };
          installHeaderManagedRuntime();

          const defineGetter = (object, key, getter) => {
            try {
              Object.defineProperty(object, key, { configurable: true, get: getter });
            } catch {}
          };

          const inputMediaFeaturePattern =
            /\\(\\s*((?:any-)?(?:pointer|hover))\\s*(?::\\s*(none|coarse|fine|hover)\\s*)?\\)/gi;
          const inputMediaFeatureMatches = (feature, value) => {
            const input = runtime.environment?.input;
            if (!input) return null;
            const normalizedFeature = String(feature).toLowerCase();
            const normalizedValue = value == null ? null : String(value).toLowerCase();
            let availableValues;
            switch (normalizedFeature) {
            case 'pointer':
              availableValues = [input.primaryPointer];
              break;
            case 'any-pointer':
              availableValues = input.anyPointers;
              break;
            case 'hover':
              availableValues = [input.primaryHover];
              break;
            case 'any-hover':
              availableValues = input.anyHovers;
              break;
            default:
              return null;
            }
            const values = Array.isArray(availableValues)
              ? availableValues.map((entry) => String(entry).toLowerCase())
              : [];
            if (normalizedValue == null) return values.some((entry) => entry !== 'none');
            return values.includes(normalizedValue);
          };
          const emulateInputMediaQuery = (query) => String(query).replace(
            inputMediaFeaturePattern,
            (source, feature, value) => {
              const matches = inputMediaFeatureMatches(feature, value);
              if (matches == null) return source;
              return matches ? '(min-width: 0px)' : '(min-width: 100000000px)';
            }
          );
          const emulatedMediaQueryEvent = (query, matches) => {
            try {
              return new MediaQueryListEvent('change', { media: query, matches });
            } catch {
              const event = new Event('change');
              defineGetter(event, 'media', () => query);
              defineGetter(event, 'matches', () => matches);
              return event;
            }
          };
          const installInputCapabilityEmulation = () => {
            if (runtime.inputCapabilityEmulationInstalled) return;
            runtime.inputCapabilityEmulationInstalled = true;

            const nativeMatchMedia = window.matchMedia.bind(window);
            window.matchMedia = (query) => {
              const originalQuery = String(query);
              const emulatedQuery = emulateInputMediaQuery(originalQuery);
              const nativeList = nativeMatchMedia(emulatedQuery);
              if (emulatedQuery === originalQuery) return nativeList;

              const listenerWrappers = new Map();
              let onchange = null;
              let onchangeWrapper = null;
              let proxy;
              const wrapListener = (listener) => {
                if (listener == null) return listener;
                const existing = listenerWrappers.get(listener);
                if (existing) return existing;
                const wrapped = () => {
                  const event = emulatedMediaQueryEvent(originalQuery, nativeList.matches);
                  if (typeof listener === 'function') listener.call(proxy, event);
                  else listener.handleEvent?.call(listener, event);
                };
                listenerWrappers.set(listener, wrapped);
                return wrapped;
              };

              proxy = new Proxy(nativeList, {
                get(target, property) {
                  if (property === 'media') return originalQuery;
                  if (property === 'onchange') return onchange;
                  if (property === 'addListener') {
                    return (listener) => target.addListener(wrapListener(listener));
                  }
                  if (property === 'removeListener') {
                    return (listener) => {
                      const wrapped = listenerWrappers.get(listener);
                      if (wrapped) target.removeListener(wrapped);
                      listenerWrappers.delete(listener);
                    };
                  }
                  if (property === 'addEventListener') {
                    return (type, listener, options) => {
                      target.addEventListener(
                        type,
                        type === 'change' ? wrapListener(listener) : listener,
                        options
                      );
                    };
                  }
                  if (property === 'removeEventListener') {
                    return (type, listener, options) => {
                      const wrapped = type === 'change'
                        ? listenerWrappers.get(listener)
                        : listener;
                      target.removeEventListener(type, wrapped || listener, options);
                      if (type === 'change') listenerWrappers.delete(listener);
                    };
                  }
                  const result = Reflect.get(target, property, target);
                  return typeof result === 'function' ? result.bind(target) : result;
                },
                set(target, property, value) {
                  if (property !== 'onchange') return Reflect.set(target, property, value, target);
                  if (onchangeWrapper) target.removeEventListener('change', onchangeWrapper);
                  onchange = typeof value === 'function' ? value : null;
                  onchangeWrapper = onchange ? wrapListener(onchange) : null;
                  if (onchangeWrapper) target.addEventListener('change', onchangeWrapper);
                  return true;
                }
              });
              return proxy;
            };

            const rewriteMediaList = (media) => {
              try {
                const source = media.mediaText;
                const emulated = emulateInputMediaQuery(source);
                if (source !== emulated) media.mediaText = emulated;
              } catch {}
            };
            const rewriteRule = (rule, visited) => {
              if (!rule || visited.has(rule)) return;
              visited.add(rule);
              if (rule.media) rewriteMediaList(rule.media);
              if (rule.styleSheet) rewriteStyleSheet(rule.styleSheet, visited);
              if (rule.cssRules) {
                for (const nestedRule of Array.from(rule.cssRules)) {
                  rewriteRule(nestedRule, visited);
                }
              }
            };
            const rewriteStyleSheet = (sheet, visited = new Set()) => {
              if (!sheet || visited.has(sheet)) return;
              visited.add(sheet);
              let rules;
              try {
                rules = Array.from(sheet.cssRules || []);
              } catch {
                return;
              }
              for (const rule of rules) {
                rewriteRule(rule, visited);
              }
            };
            const rewriteMediaAttribute = (element) => {
              if (!(element instanceof Element) || !element.hasAttribute('media')) return;
              const source = element.getAttribute('media') || '';
              const emulated = emulateInputMediaQuery(source);
              if (source !== emulated) element.setAttribute('media', emulated);
            };
            const linkedStyleSheets = new WeakSet();
            const processElement = (element) => {
              if (!(element instanceof Element)) return;
              rewriteMediaAttribute(element);
              if (element instanceof HTMLStyleElement) rewriteStyleSheet(element.sheet);
              if (element instanceof HTMLLinkElement &&
                  element.relList?.contains('stylesheet') &&
                  !linkedStyleSheets.has(element)) {
                linkedStyleSheets.add(element);
                element.addEventListener('load', () => rewriteStyleSheet(element.sheet));
                rewriteStyleSheet(element.sheet);
              }
              for (const child of element.querySelectorAll('style, link[rel~="stylesheet"], [media]')) {
                rewriteMediaAttribute(child);
                if (child instanceof HTMLStyleElement) rewriteStyleSheet(child.sheet);
                if (child instanceof HTMLLinkElement &&
                    child.relList?.contains('stylesheet') &&
                    !linkedStyleSheets.has(child)) {
                  linkedStyleSheets.add(child);
                  child.addEventListener('load', () => rewriteStyleSheet(child.sheet));
                  rewriteStyleSheet(child.sheet);
                }
              }
            };
            const processAllStyleSheets = () => {
              for (const sheet of Array.from(document.styleSheets || [])) rewriteStyleSheet(sheet);
              if (document.documentElement) processElement(document.documentElement);
            };

            const wrapRuleInsertion = (prototype, methodName) => {
              const nativeMethod = prototype?.[methodName];
              if (typeof nativeMethod !== 'function') return;
              prototype[methodName] = function(rule, ...args) {
                const index = Reflect.apply(nativeMethod, this, [rule, ...args]);
                try {
                  rewriteRule(this.cssRules[index], new Set());
                } catch {}
                return index;
              };
            };
            wrapRuleInsertion(CSSStyleSheet.prototype, 'insertRule');
            if (typeof CSSGroupingRule !== 'undefined') {
              wrapRuleInsertion(CSSGroupingRule.prototype, 'insertRule');
            }
            const nativeReplace = CSSStyleSheet.prototype.replace;
            if (typeof nativeReplace === 'function') {
              CSSStyleSheet.prototype.replace = function(text) {
                return Reflect.apply(nativeReplace, this, [text]).then((result) => {
                  rewriteStyleSheet(this);
                  return result;
                });
              };
            }
            const nativeReplaceSync = CSSStyleSheet.prototype.replaceSync;
            if (typeof nativeReplaceSync === 'function') {
              CSSStyleSheet.prototype.replaceSync = function(text) {
                const result = Reflect.apply(nativeReplaceSync, this, [text]);
                rewriteStyleSheet(this);
                return result;
              };
            }
            if (typeof MediaList !== 'undefined') {
              try {
                const mediaText = Object.getOwnPropertyDescriptor(MediaList.prototype, 'mediaText');
                if (mediaText?.get && mediaText?.set) {
                  Object.defineProperty(MediaList.prototype, 'mediaText', {
                    configurable: mediaText.configurable,
                    enumerable: mediaText.enumerable,
                    get: mediaText.get,
                    set(value) {
                      return Reflect.apply(mediaText.set, this, [emulateInputMediaQuery(value)]);
                    }
                  });
                }
                for (const methodName of ['appendMedium', 'deleteMedium']) {
                  const nativeMethod = MediaList.prototype[methodName];
                  if (typeof nativeMethod !== 'function') continue;
                  MediaList.prototype[methodName] = function(query) {
                    return Reflect.apply(nativeMethod, this, [emulateInputMediaQuery(query)]);
                  };
                }
              } catch {}
            }
            const nativeSetAttribute = Element.prototype.setAttribute;
            Element.prototype.setAttribute = function(name, value) {
              const nextValue = String(name).toLowerCase() === 'media'
                ? emulateInputMediaQuery(value)
                : value;
              return Reflect.apply(nativeSetAttribute, this, [name, nextValue]);
            };

            new MutationObserver((records) => {
              for (const record of records) {
                if (record.type === 'attributes') {
                  rewriteMediaAttribute(record.target);
                  continue;
                }
                if (record.type === 'characterData') {
                  if (record.target.parentElement instanceof HTMLStyleElement) {
                    rewriteStyleSheet(record.target.parentElement.sheet);
                  }
                  continue;
                }
                for (const node of record.addedNodes) {
                  if (node instanceof Element) processElement(node);
                  else if (node.parentElement instanceof HTMLStyleElement) {
                    rewriteStyleSheet(node.parentElement.sheet);
                  }
                }
              }
            }).observe(document, {
              attributes: true,
              attributeFilter: ['media'],
              characterData: true,
              childList: true,
              subtree: true
            });
            document.addEventListener('DOMContentLoaded', processAllStyleSheets, { once: true });
            window.addEventListener('load', processAllStyleSheets, { once: true });
            queueMicrotask(processAllStyleSheets);
          };

          const applyDocumentEnvironment = () => {
            const root = document.documentElement;
            if (!root) return;
            const safe = runtime.safeArea;
            root.dataset.viewdeckEngine = 'webkit';
            root.dataset.viewdeckDevice = runtime.device.model;
            root.dataset.viewdeckSafeArea = JSON.stringify(safe);
            root.style.setProperty('--viewdeck-safe-area-inset-top', safe.top + 'px');
            root.style.setProperty('--viewdeck-safe-area-inset-right', safe.right + 'px');
            root.style.setProperty('--viewdeck-safe-area-inset-bottom', safe.bottom + 'px');
            root.style.setProperty('--viewdeck-safe-area-inset-left', safe.left + 'px');

            if (runtime.forcePageInsets) {
              if (!runtime.pageInsetStyle?.isConnected) {
                runtime.pageInsetStyle = document.createElement('style');
                runtime.pageInsetStyle.textContent = `
                  html {
                    box-sizing: border-box !important;
                    padding-top: var(--viewdeck-safe-area-inset-top) !important;
                    padding-right: var(--viewdeck-safe-area-inset-right) !important;
                    padding-bottom: var(--viewdeck-safe-area-inset-bottom) !important;
                    padding-left: var(--viewdeck-safe-area-inset-left) !important;
                    min-height: 100% !important;
                  }
                `;
                (document.head || root).appendChild(runtime.pageInsetStyle);
              }
            } else {
              runtime.pageInsetStyle?.remove();
              runtime.pageInsetStyle = null;
            }
          };

          window.__VIEWDECK_APPLY_ENVIRONMENT__ = (next, options = {}) => {
            const previousLandscape = runtime.landscape;
            runtime.safeArea = next.safeArea;
            runtime.device = next.device;
            runtime.environment = next.environment;
            runtime.navigator = next.navigator;
            runtime.landscape = !!next.landscape;
            runtime.forcePageInsets = !!next.forcePageInsets;

            applyDocumentEnvironment();
            if (!document.documentElement) {
              document.addEventListener('DOMContentLoaded', applyDocumentEnvironment, { once: true });
            }
            for (let index = 0; index < window.frames.length; index += 1) {
              const child = window.frames[index];
              try {
                child.postMessage({
                  __viewdeckEnvironmentUpdate: true,
                  environment: next,
                  options
                }, '*');
              } catch {}
            }

            if (!options.notify) return;
            const notifyPage = () => {
              window.dispatchEvent(new CustomEvent('viewdeck:safe-area-change', {
                detail: runtime.safeArea
              }));
              window.dispatchEvent(new CustomEvent('viewdeck:device-change', {
                detail: runtime.device
              }));
              if (options.orientationChanged && previousLandscape !== runtime.landscape) {
                try {
                  runtime.orientationTarget.dispatchEvent(new Event('change'));
                } catch {}
                window.dispatchEvent(new Event('orientationchange'));
              }
            };
            notifyPage();
          };

          runtime.safeArea = initialEnvironment.safeArea;
          runtime.device = initialEnvironment.device;
          runtime.environment = initialEnvironment.environment;
          runtime.navigator = initialEnvironment.navigator;
          runtime.landscape = initialEnvironment.landscape;
          runtime.forcePageInsets = initialEnvironment.forcePageInsets;
          runtime.orientationTarget = new EventTarget();
          installInputCapabilityEmulation();

          let orientationChangeHandler = null;
          try {
            Object.defineProperty(runtime.orientationTarget, 'onchange', {
              configurable: true,
              get: () => orientationChangeHandler,
              set: (handler) => {
                if (orientationChangeHandler) {
                  runtime.orientationTarget.removeEventListener('change', orientationChangeHandler);
                }
                orientationChangeHandler = typeof handler === 'function' ? handler : null;
                if (orientationChangeHandler) {
                  runtime.orientationTarget.addEventListener('change', orientationChangeHandler);
                }
              }
            });
          } catch {}

          // macOS WebKit reports zero for CSS safe-area environment variables
          // unless native content insets are enabled. Keep the page full-bleed,
          // but emulate the common JS measurement pattern used on iOS.
          try {
            const nativeGetComputedStyle = window.getComputedStyle.bind(window);
            const sides = ['top', 'right', 'bottom', 'left'];
            window.getComputedStyle = (element, pseudoElement) => {
              const computed = nativeGetComputedStyle(element, pseudoElement);
              if (pseudoElement || !element?.style) return computed;
              const overrides = {};
              for (const side of sides) {
                const inlineValue = element.style.getPropertyValue('padding-' + side);
                if (inlineValue.includes('env(safe-area-inset-' + side + ')')) {
                  overrides['padding' + side[0].toUpperCase() + side.slice(1)] =
                    runtime.safeArea[side] + 'px';
                }
              }
              if (Object.keys(overrides).length === 0) return computed;
              return new Proxy(computed, {
                get(target, property) {
                  if (typeof property === 'string' && property in overrides) return overrides[property];
                  if (property === 'getPropertyValue') {
                    return (name) => {
                      const camelName = name.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
                      return camelName in overrides ? overrides[camelName] : target.getPropertyValue(name);
                    };
                  }
                  const value = Reflect.get(target, property, target);
                  return typeof value === 'function' ? value.bind(target) : value;
                },
              });
            };
          } catch {}

          // WKWebView can fail to composite a WebGPU canvas that is fixed-positioned.
          try {
            const getContext = HTMLCanvasElement.prototype.getContext;
            HTMLCanvasElement.prototype.getContext = function(type, ...args) {
              const context = Reflect.apply(getContext, this, [type, ...args]);
              if (String(type).toLowerCase() === 'webgpu') {
                const canvas = this;
                const ensureCompositablePosition = () => {
                  if (getComputedStyle(canvas).position === 'fixed') {
                    canvas.style.setProperty('position', 'absolute', 'important');
                  }
                };
                ensureCompositablePosition();
                queueMicrotask(ensureCompositablePosition);
                window.addEventListener('load', ensureCompositablePosition, { once: true });
                new MutationObserver(ensureCompositablePosition).observe(canvas, {
                  attributes: true,
                  attributeFilter: ['class', 'style'],
                });
              }
              return context;
            };
          } catch {}

          defineGetter(window, 'devicePixelRatio', () => runtime.device.pixelRatio);
          defineGetter(window, 'orientation', () => runtime.landscape ? 90 : 0);
          try {
            defineGetter(Screen.prototype, 'width', () => runtime.device.screenSize.width);
            defineGetter(Screen.prototype, 'height', () => runtime.device.screenSize.height);
            defineGetter(Screen.prototype, 'availWidth', () => runtime.device.screenSize.width);
            defineGetter(Screen.prototype, 'availHeight', () => runtime.device.screenSize.height);
            defineGetter(Screen.prototype, 'orientation', () => runtime.orientationTarget);
            defineGetter(runtime.orientationTarget, 'type', () =>
              runtime.landscape ? 'landscape-primary' : 'portrait-primary'
            );
            defineGetter(runtime.orientationTarget, 'angle', () => runtime.landscape ? 90 : 0);
            defineGetter(Navigator.prototype, 'platform', () => runtime.navigator.platform);
            defineGetter(Navigator.prototype, 'maxTouchPoints', () => runtime.navigator.maxTouchPoints);
          } catch {}

          window.addEventListener('message', (event) => {
            if (event.source !== window.parent) return;
            if (!event.data?.__viewdeckEnvironmentUpdate) return;
            window.__VIEWDECK_APPLY_ENVIRONMENT__(
              event.data.environment,
              event.data.options
            );
          });
          window.__VIEWDECK_APPLY_ENVIRONMENT__(initialEnvironment, { notify: false });
        })();
        """
    }

    private static let qaBootstrapScript = """
    (() => {
      if (window.__VIEWDECK_QA__) return;

      const state = {
        recording: false,
        replaying: false,
        startedAt: 0,
        sequence: 0,
        replayPointerTargets: new Map(),
      };

      const finite = (value, fallback = 0) => Number.isFinite(Number(value)) ? Number(value) : fallback;
      const cssEscape = (value) => {
        try { return CSS.escape(value); } catch { return String(value).replace(/[^a-zA-Z0-9_-]/g, '\\\\$&'); }
      };
      const selectorFor = (element) => {
        if (!(element instanceof Element)) return null;
        if (element.id) return '#' + cssEscape(element.id);
        const pieces = [];
        let current = element;
        while (current && current.nodeType === Node.ELEMENT_NODE && pieces.length < 7) {
          let piece = current.localName || current.tagName.toLowerCase();
          const stableClasses = Array.from(current.classList || []).filter(Boolean).slice(0, 2);
          if (stableClasses.length) piece += '.' + stableClasses.map(cssEscape).join('.');
          const parent = current.parentElement;
          if (parent) {
            const peers = Array.from(parent.children).filter((child) => child.localName === current.localName);
            if (peers.length > 1) piece += `:nth-of-type(${peers.indexOf(current) + 1})`;
          }
          pieces.unshift(piece);
          const candidate = pieces.join(' > ');
          try {
            if (document.querySelectorAll(candidate).length === 1) return candidate;
          } catch {}
          current = parent;
        }
        return pieces.join(' > ') || null;
      };
      const targetHint = (target) => {
        const element = target instanceof Element ? target : null;
        if (!element) return null;
        const rectangle = element.getBoundingClientRect();
        const text = (element.innerText || element.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 160);
        return {
          selector: selectorFor(element),
          tagName: element.tagName?.toLowerCase() || null,
          id: element.id || null,
          className: typeof element.className === 'string' ? element.className.slice(0, 240) : null,
          role: element.getAttribute('role'),
          ariaLabel: element.getAttribute('aria-label'),
          name: element.getAttribute('name'),
          text: text || null,
          isCanvas: element instanceof HTMLCanvasElement,
          rectangle: {
            x: rectangle.x,
            y: rectangle.y,
            width: rectangle.width,
            height: rectangle.height,
          },
        };
      };
      const pointerPayload = (event) => ({
        clientX: finite(event.clientX),
        clientY: finite(event.clientY),
        normalizedX: innerWidth > 0 ? finite(event.clientX) / innerWidth : 0,
        normalizedY: innerHeight > 0 ? finite(event.clientY) / innerHeight : 0,
        pageX: finite(event.pageX),
        pageY: finite(event.pageY),
        screenX: finite(event.screenX),
        screenY: finite(event.screenY),
        movementX: finite(event.movementX),
        movementY: finite(event.movementY),
        button: finite(event.button),
        buttons: finite(event.buttons),
        detail: finite(event.detail),
        pointerID: finite(event.pointerId, 1),
        pointerType: event.pointerType || 'mouse',
        isPrimary: event.isPrimary !== false,
        pressure: finite(event.pressure),
        tangentialPressure: finite(event.tangentialPressure),
        tiltX: finite(event.tiltX),
        tiltY: finite(event.tiltY),
        twist: finite(event.twist),
        width: finite(event.width, 1),
        height: finite(event.height, 1),
      });
      const keyboardPayload = (event) => ({
        key: event.key || '',
        code: event.code || '',
        location: finite(event.location),
        repeat: Boolean(event.repeat),
        isComposing: Boolean(event.isComposing),
        keyCode: finite(event.keyCode),
        charCode: finite(event.charCode),
        altKey: Boolean(event.altKey),
        ctrlKey: Boolean(event.ctrlKey),
        metaKey: Boolean(event.metaKey),
        shiftKey: Boolean(event.shiftKey),
      });
      const formPayload = (event) => {
        const target = event.target;
        if (!(target instanceof HTMLInputElement ||
              target instanceof HTMLTextAreaElement ||
              target instanceof HTMLSelectElement)) return null;
        const redacted = target instanceof HTMLInputElement && target.type === 'password';
        return {
          value: redacted ? null : target.value,
          inputType: event.inputType || null,
          data: redacted ? null : (event.data ?? null),
          checked: 'checked' in target ? Boolean(target.checked) : null,
          selectionStart: 'selectionStart' in target ? target.selectionStart : null,
          selectionEnd: 'selectionEnd' in target ? target.selectionEnd : null,
          redacted,
        };
      };
      const post = (type, event, extra = {}) => {
        if (!state.recording || state.replaying) return;
        const message = {
          id: crypto.randomUUID ? crypto.randomUUID() : `event-${++state.sequence}`,
          type,
          atMilliseconds: Math.max(0, performance.now() - state.startedAt),
          pageURL: location.href,
          viewport: { width: innerWidth, height: innerHeight },
          target: targetHint(event.target),
          ...extra,
        };
        try { window.webkit.messageHandlers.viewdeckQA.postMessage(message); } catch {}
      };

      for (const type of ['pointerdown', 'pointermove', 'pointerup', 'pointercancel']) {
        addEventListener(type, (event) => post(type, event, { pointer: pointerPayload(event) }), true);
      }
      for (const type of ['mousedown', 'mousemove', 'mouseup', 'click', 'dblclick']) {
        addEventListener(type, (event) => post(type, event, { pointer: pointerPayload(event) }), true);
      }
      for (const type of ['keydown', 'keyup']) {
        addEventListener(type, (event) => post(type, event, { keyboard: keyboardPayload(event) }), true);
      }
      for (const type of ['input', 'change']) {
        addEventListener(type, (event) => post(type, event, { form: formPayload(event) }), true);
      }

      const resolveTarget = (record, x, y) => {
        if (!record.target?.isCanvas && record.target?.selector) {
          try {
            const selected = document.querySelector(record.target.selector);
            if (selected) return selected;
          } catch {}
        }
        return document.elementFromPoint(x, y) || document.activeElement || document.body || document.documentElement;
      };
      const coordinates = (record) => {
        const pointer = record.pointer || {};
        const x = Number.isFinite(pointer.normalizedX) ? pointer.normalizedX * innerWidth : finite(pointer.clientX);
        const y = Number.isFinite(pointer.normalizedY) ? pointer.normalizedY * innerHeight : finite(pointer.clientY);
        return { x, y };
      };
      const replayPointer = (record) => {
        const pointer = record.pointer || {};
        const { x, y } = coordinates(record);
        const pointerID = finite(pointer.pointerID, 1);
        let target = state.replayPointerTargets.get(pointerID);
        if (!target?.isConnected || record.type === 'pointerdown' || record.type === 'mousedown') {
          target = resolveTarget(record, x, y);
          state.replayPointerTargets.set(pointerID, target);
        }
        const common = {
          bubbles: true,
          cancelable: true,
          composed: true,
          clientX: x,
          clientY: y,
          screenX: finite(pointer.screenX, x),
          screenY: finite(pointer.screenY, y),
          button: finite(pointer.button),
          buttons: finite(pointer.buttons),
          detail: finite(pointer.detail),
          altKey: false,
          ctrlKey: false,
          metaKey: false,
          shiftKey: false,
        };
        let event;
        if (record.type.startsWith('pointer') && typeof PointerEvent === 'function') {
          event = new PointerEvent(record.type, {
            ...common,
            pointerId: pointerID,
            pointerType: pointer.pointerType || 'mouse',
            isPrimary: pointer.isPrimary !== false,
            pressure: finite(pointer.pressure),
            tangentialPressure: finite(pointer.tangentialPressure),
            tiltX: finite(pointer.tiltX),
            tiltY: finite(pointer.tiltY),
            twist: finite(pointer.twist),
            width: finite(pointer.width, 1),
            height: finite(pointer.height, 1),
          });
        } else {
          event = new MouseEvent(record.type, common);
        }
        target.dispatchEvent(event);
        if (record.type === 'pointerdown' || record.type === 'mousedown') {
          try { target.focus({ preventScroll: true }); } catch {}
        }
        if (['pointerup', 'pointercancel', 'mouseup'].includes(record.type)) {
          state.replayPointerTargets.delete(pointerID);
        }
      };
      const replayKeyboard = (record) => {
        const keyboard = record.keyboard || {};
        const { x, y } = coordinates(record);
        const target = resolveTarget(record, x, y);
        target.dispatchEvent(new KeyboardEvent(record.type, {
          bubbles: true,
          cancelable: true,
          composed: true,
          key: keyboard.key || '',
          code: keyboard.code || '',
          location: finite(keyboard.location),
          repeat: Boolean(keyboard.repeatKey),
          isComposing: Boolean(keyboard.isComposing),
          altKey: Boolean(keyboard.alt),
          ctrlKey: Boolean(keyboard.control),
          metaKey: Boolean(keyboard.meta),
          shiftKey: Boolean(keyboard.shift),
        }));
      };
      const replayForm = (record) => {
        const form = record.form || {};
        if (form.redacted) return;
        const target = resolveTarget(record, 0, 0);
        if ('value' in target && form.value != null) target.value = form.value;
        if ('checked' in target && form.checked != null) target.checked = Boolean(form.checked);
        if (typeof target.setSelectionRange === 'function' &&
            form.selectionStart != null && form.selectionEnd != null) {
          try { target.setSelectionRange(form.selectionStart, form.selectionEnd); } catch {}
        }
        const EventType = record.type === 'input' && typeof InputEvent === 'function' ? InputEvent : Event;
        target.dispatchEvent(new EventType(record.type, {
          bubbles: true,
          cancelable: false,
          composed: true,
          inputType: form.inputType || undefined,
          data: form.data || undefined,
        }));
      };

      window.__VIEWDECK_QA__ = {
        start() {
          state.startedAt = performance.now();
          state.sequence = 0;
          state.recording = true;
          state.replaying = false;
          return { startedAt: new Date().toISOString(), url: location.href };
        },
        stop() {
          state.recording = false;
          return { durationMilliseconds: Math.max(0, performance.now() - state.startedAt) };
        },
        replay(record) {
          state.replaying = true;
          try {
            if (record.pointer) replayPointer(record);
            else if (record.keyboard) replayKeyboard(record);
            else if (record.form) replayForm(record);
            return true;
          } finally {
            state.replaying = false;
          }
        },
        get recording() { return state.recording; },
      };
    })();
    """

    private static let qaRuntimeEnvironmentScript = """
    (() => {
      const safeCall = (body, fallback = null) => {
        try { return body(); } catch { return fallback; }
      };
      const webgl = (() => {
        const canvas = document.querySelector('canvas');
        if (!canvas) return null;
        const gl = safeCall(() => canvas.getContext('webgl2') || canvas.getContext('webgl'));
        if (!gl) return null;
        const extension = safeCall(() => gl.getExtension('WEBGL_debug_renderer_info'));
        return {
          version: safeCall(() => gl.getParameter(gl.VERSION)),
          shadingLanguageVersion: safeCall(() => gl.getParameter(gl.SHADING_LANGUAGE_VERSION)),
          vendor: safeCall(() => gl.getParameter(gl.VENDOR)),
          renderer: safeCall(() => gl.getParameter(gl.RENDERER)),
          unmaskedVendor: extension ? safeCall(() => gl.getParameter(extension.UNMASKED_VENDOR_WEBGL)) : null,
          unmaskedRenderer: extension ? safeCall(() => gl.getParameter(extension.UNMASKED_RENDERER_WEBGL)) : null,
          maxTextureSize: safeCall(() => gl.getParameter(gl.MAX_TEXTURE_SIZE)),
        };
      })();
      const rootStyle = document.documentElement ? getComputedStyle(document.documentElement) : null;
      const visual = window.visualViewport;
      return JSON.stringify({
        capturedAt: new Date().toISOString(),
        page: {
          url: location.href,
          origin: location.origin,
          protocol: location.protocol,
          title: document.title,
          referrer: document.referrer,
          readyState: document.readyState,
          visibilityState: document.visibilityState,
          characterSet: document.characterSet,
          contentType: document.contentType,
          compatMode: document.compatMode,
          historyLength: history.length,
          secureContext: window.isSecureContext,
          crossOriginIsolated: window.crossOriginIsolated,
        },
        navigator: {
          userAgent: navigator.userAgent,
          appVersion: navigator.appVersion,
          platform: navigator.platform,
          vendor: navigator.vendor,
          language: navigator.language,
          languages: Array.from(navigator.languages || []),
          cookieEnabled: navigator.cookieEnabled,
          onLine: navigator.onLine,
          hardwareConcurrency: navigator.hardwareConcurrency,
          deviceMemory: navigator.deviceMemory ?? null,
          maxTouchPoints: navigator.maxTouchPoints,
          webdriver: navigator.webdriver,
          pdfViewerEnabled: navigator.pdfViewerEnabled,
        },
        window: {
          innerWidth,
          innerHeight,
          outerWidth,
          outerHeight,
          devicePixelRatio,
          scrollX,
          scrollY,
          screenX,
          screenY,
        },
        visualViewport: visual ? {
          width: visual.width,
          height: visual.height,
          offsetLeft: visual.offsetLeft,
          offsetTop: visual.offsetTop,
          pageLeft: visual.pageLeft,
          pageTop: visual.pageTop,
          scale: visual.scale,
        } : null,
        screen: {
          width: screen.width,
          height: screen.height,
          availWidth: screen.availWidth,
          availHeight: screen.availHeight,
          availLeft: screen.availLeft,
          availTop: screen.availTop,
          colorDepth: screen.colorDepth,
          pixelDepth: screen.pixelDepth,
          orientation: screen.orientation ? {
            type: screen.orientation.type,
            angle: screen.orientation.angle,
          } : null,
        },
        document: {
          clientWidth: document.documentElement?.clientWidth ?? 0,
          clientHeight: document.documentElement?.clientHeight ?? 0,
          scrollWidth: document.documentElement?.scrollWidth ?? 0,
          scrollHeight: document.documentElement?.scrollHeight ?? 0,
          bodyWidth: document.body?.getBoundingClientRect().width ?? 0,
          bodyHeight: document.body?.getBoundingClientRect().height ?? 0,
          activeElement: document.activeElement?.tagName?.toLowerCase() ?? null,
          canvasCount: document.querySelectorAll('canvas').length,
        },
        viewDeck: {
          device: document.documentElement?.dataset.viewdeckDevice ?? null,
          engine: document.documentElement?.dataset.viewdeckEngine ?? null,
          safeAreaDataset: document.documentElement?.dataset.viewdeckSafeArea ?? null,
          safeAreaCSS: rootStyle ? {
            top: rootStyle.getPropertyValue('--viewdeck-safe-area-inset-top').trim(),
            right: rootStyle.getPropertyValue('--viewdeck-safe-area-inset-right').trim(),
            bottom: rootStyle.getPropertyValue('--viewdeck-safe-area-inset-bottom').trim(),
            left: rootStyle.getPropertyValue('--viewdeck-safe-area-inset-left').trim(),
          } : null,
        },
        preferences: {
          colorScheme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
          reducedMotion: matchMedia('(prefers-reduced-motion: reduce)').matches,
          reducedTransparency: matchMedia('(prefers-reduced-transparency: reduce)').matches,
          contrastMore: matchMedia('(prefers-contrast: more)').matches,
          forcedColors: matchMedia('(forced-colors: active)').matches,
          pointerCoarse: matchMedia('(pointer: coarse)').matches,
          pointerFine: matchMedia('(pointer: fine)').matches,
          anyPointerCoarse: matchMedia('(any-pointer: coarse)').matches,
          anyPointerFine: matchMedia('(any-pointer: fine)').matches,
          hoverNone: matchMedia('(hover: none)').matches,
          hoverHover: matchMedia('(hover: hover)').matches,
          anyHoverNone: matchMedia('(any-hover: none)').matches,
          anyHoverHover: matchMedia('(any-hover: hover)').matches,
        },
        storage: {
          localStorageKeys: safeCall(() => Object.keys(localStorage), []),
          sessionStorageKeys: safeCall(() => Object.keys(sessionStorage), []),
          indexedDBAvailable: Boolean(window.indexedDB),
          cachesAvailable: Boolean(window.caches),
        },
        graphics: {
          webGL: webgl,
          webGPUAvailable: Boolean(navigator.gpu),
        },
        time: {
          timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
          locale: Intl.DateTimeFormat().resolvedOptions().locale,
          performanceTimeOrigin: performance.timeOrigin,
        },
      });
    })();
    """

    private static let diagnosticsBootstrapScript = """
    (() => {
      if (window.__VIEWDECK_DIAGNOSTICS__) return;
      const diagnostics = {
        startedAt: new Date().toISOString(),
        consoleMessages: [],
        pageErrors: []
      };
      window.__VIEWDECK_DIAGNOSTICS__ = diagnostics;

      const serialize = (value) => {
        if (value instanceof Error) {
          return { name: value.name, message: value.message, stack: value.stack || null };
        }
        if (typeof value === 'string' || typeof value === 'number' ||
            typeof value === 'boolean' || value == null) return value;
        try {
          return JSON.parse(JSON.stringify(value));
        } catch {
          try { return String(value); } catch { return '[unserializable]'; }
        }
      };
      const append = (collection, value) => {
        collection.push(value);
        if (collection.length > 200) collection.splice(0, collection.length - 200);
      };

      const networkRecords = [];
      const pendingNetworkRecords = new Map();
      const completedPerformanceEntries = new Set();
      const elementNetworkRecords = new WeakMap();
      const xhrNetworkRecords = new WeakMap();
      let networkSequence = 0;
      let networkRevision = 0;
      const rounded = (value) => Math.round(Number(value || 0) * 100) / 100;
      const absoluteURL = (value) => {
        if (!value) return null;
        try {
          const url = new URL(String(value), location.href);
          return ['http:', 'https:', 'file:'].includes(url.protocol) ? url.href : null;
        } catch { return null; }
      };
      const networkKey = (url, initiatorType) => `${initiatorType}|${url}`;
      const trimNetworkRecords = () => {
        while (networkRecords.length > 500) {
          const index = networkRecords.findIndex((record) => record.status !== 'pending');
          if (index < 0) break;
          networkRecords.splice(index, 1);
        }
      };
      const beginNetworkRecord = (value, initiatorType, startTime = performance.now()) => {
        const url = absoluteURL(value);
        if (!url) return null;
        const type = initiatorType || 'other';
        const key = networkKey(url, type);
        const existing = pendingNetworkRecords.get(key);
        if (existing) return existing;
        const record = {
          id: String(++networkSequence),
          url,
          initiatorType: type,
          status: 'pending',
          startTimeMilliseconds: rounded(startTime),
          durationMilliseconds: null,
          transferSizeBytes: null,
          encodedBodySizeBytes: null,
          decodedBodySizeBytes: null,
          responseStatus: null,
          fromCache: false,
          error: null
        };
        networkRecords.push(record);
        pendingNetworkRecords.set(key, record);
        trimNetworkRecords();
        networkRevision += 1;
        return record;
      };
      const finishNetworkRecord = (record, status, details = {}) => {
        if (!record) return;
        Object.assign(record, details, { status });
        if (record.durationMilliseconds == null) {
          record.durationMilliseconds = rounded(performance.now() - record.startTimeMilliseconds);
        }
        pendingNetworkRecords.delete(networkKey(record.url, record.initiatorType));
        networkRevision += 1;
      };
      const completePerformanceEntry = (entry) => {
        const entryKey = `${entry.entryType}|${entry.name}|${entry.startTime}|${entry.duration}`;
        if (completedPerformanceEntries.has(entryKey)) return;
        completedPerformanceEntries.add(entryKey);
        const type = entry.entryType === 'navigation'
          ? 'document'
          : (entry.initiatorType || 'other');
        const url = absoluteURL(entry.name || location.href);
        if (!url) return;
        const key = networkKey(url, type);
        const record = pendingNetworkRecords.get(key)
          || [...networkRecords].reverse().find((candidate) =>
            candidate.url === url && candidate.initiatorType === type &&
            Math.abs(candidate.startTimeMilliseconds - entry.startTime) < 250
          )
          || beginNetworkRecord(url, type, entry.startTime);
        const observedResponseStatus = Number.isFinite(entry.responseStatus) && entry.responseStatus > 0
          ? entry.responseStatus
          : null;
        const responseStatus = observedResponseStatus ?? record?.responseStatus ?? null;
        const failed = record?.status === 'failed' || (responseStatus != null && responseStatus >= 400);
        finishNetworkRecord(record, failed ? 'failed' : 'complete', {
          startTimeMilliseconds: rounded(entry.startTime),
          durationMilliseconds: rounded(entry.duration),
          transferSizeBytes: Number.isFinite(entry.transferSize) ? entry.transferSize : null,
          encodedBodySizeBytes: Number.isFinite(entry.encodedBodySize) ? entry.encodedBodySize : null,
          decodedBodySizeBytes: Number.isFinite(entry.decodedBodySize) ? entry.decodedBodySize : null,
          responseStatus,
          fromCache: entry.transferSize === 0 && entry.decodedBodySize > 0,
          error: responseStatus != null && responseStatus >= 400
            ? `HTTP ${responseStatus}`
            : (record?.error || null)
        });
      };
      const elementRequest = (element) => {
        if (!(element instanceof Element)) return null;
        let value = null;
        let type = element.localName || 'other';
        if (element instanceof HTMLLinkElement) {
          const resourceRels = new Set([
            'stylesheet', 'preload', 'modulepreload', 'icon', 'manifest', 'prefetch'
          ]);
          const rels = Array.from(element.relList || []);
          if (!rels.some((rel) => resourceRels.has(rel))) return null;
          value = element.href;
        }
        else if (element instanceof HTMLImageElement) value = element.currentSrc || element.src;
        else if (element instanceof HTMLScriptElement) value = element.src;
        else if (element instanceof HTMLIFrameElement) value = element.src;
        else if (element instanceof HTMLMediaElement) value = element.currentSrc || element.src;
        else if (element instanceof HTMLSourceElement) {
          value = element.src;
          if (element.parentElement instanceof HTMLPictureElement) type = 'img';
          else if (element.parentElement instanceof HTMLVideoElement) type = 'video';
          else if (element.parentElement instanceof HTMLAudioElement) type = 'audio';
        }
        else if (element instanceof HTMLObjectElement) value = element.data;
        else if (element instanceof HTMLEmbedElement) value = element.src;
        if (!value) return null;
        return { value, type };
      };
      const watchElement = (element) => {
        const request = elementRequest(element);
        if (!request) return;
        const record = beginNetworkRecord(request.value, request.type);
        if (record) elementNetworkRecords.set(element, record);
      };
      const scanNetworkElements = (node) => {
        if (!(node instanceof Element)) return;
        watchElement(node);
        for (const element of node.querySelectorAll(
          'link[href],img[src],script[src],iframe[src],audio[src],video[src],source[src],object[data],embed[src]'
        )) watchElement(element);
      };

      beginNetworkRecord(location.href, 'document', 0);
      try { performance.setResourceTimingBufferSize(2000); } catch {}
      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) completePerformanceEntry(entry);
        }).observe({ entryTypes: ['navigation', 'resource'] });
      } catch {}

      new MutationObserver((mutations) => {
        for (const mutation of mutations) {
          if (mutation.type === 'attributes') watchElement(mutation.target);
          for (const node of mutation.addedNodes) scanNetworkElements(node);
        }
      }).observe(document, {
        subtree: true,
        childList: true,
        attributes: true,
        attributeFilter: ['src', 'srcset', 'href', 'data']
      });
      document.addEventListener('load', (event) => {
        if (event.target === document) return;
        const record = elementNetworkRecords.get(event.target);
        finishNetworkRecord(record, 'complete');
      }, true);
      document.addEventListener('error', (event) => {
        const record = elementNetworkRecords.get(event.target);
        finishNetworkRecord(record, 'failed', { error: 'Resource failed to load' });
      }, true);

      const nativeFetch = window.fetch;
      if (typeof nativeFetch === 'function') {
        window.fetch = function(input, init) {
          const record = beginNetworkRecord(input instanceof Request ? input.url : input, 'fetch');
          return Reflect.apply(nativeFetch, this, arguments).then(
            (response) => {
              const responseStatus = response.status || null;
              const failed = responseStatus != null && responseStatus >= 400;
              finishNetworkRecord(record, failed ? 'failed' : 'complete', {
                responseStatus,
                error: failed ? `HTTP ${responseStatus}` : null
              });
              return response;
            },
            (error) => {
              finishNetworkRecord(record, 'failed', { error: String(error?.message || error) });
              throw error;
            }
          );
        };
      }

      const nativeXHROpen = XMLHttpRequest.prototype.open;
      const nativeXHRSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        xhrNetworkRecords.set(this, { url: absoluteURL(url), record: null });
        return Reflect.apply(nativeXHROpen, this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        const state = xhrNetworkRecords.get(this) || { url: null, record: null };
        state.record = beginNetworkRecord(state.url, 'xmlhttprequest');
        xhrNetworkRecords.set(this, state);
        this.addEventListener('loadend', () => {
          const failed = this.status === 0 || this.status >= 400;
          finishNetworkRecord(state.record, failed ? 'failed' : 'complete', {
            responseStatus: this.status || null,
            error: failed ? (this.status ? `HTTP ${this.status}` : 'Request failed') : null
          });
        }, { once: true });
        return Reflect.apply(nativeXHRSend, this, arguments);
      };

      diagnostics.network = {
        signature() {
          return `${performance.timeOrigin}|${networkRevision}`;
        },
        snapshot() {
          for (const entry of performance.getEntriesByType('navigation')) {
            completePerformanceEntry(entry);
          }
          for (const entry of performance.getEntriesByType('resource')) {
            completePerformanceEntry(entry);
          }
          const resources = networkRecords
            .map((record) => ({ ...record }))
            .sort((left, right) => {
              if (left.status === 'pending' && right.status !== 'pending') return -1;
              if (right.status === 'pending' && left.status !== 'pending') return 1;
              return right.startTimeMilliseconds - left.startTimeMilliseconds;
            });
          const pendingCount = resources.filter((record) => record.status === 'pending').length;
          const completedCount = resources.filter((record) => record.status === 'complete').length;
          const failedCount = resources.filter((record) => record.status === 'failed').length;
          const finishedCount = completedCount + failedCount;
          const progress = resources.length > 0 ? finishedCount / resources.length : 0;
          return {
            loading: document.readyState !== 'complete' || pendingCount > 0,
            progress: Math.max(0, Math.min(1, progress)),
            pendingCount,
            completedCount,
            failedCount,
            resources
          };
        }
      };

      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        if (typeof original !== 'function') continue;
        console[level] = function(...args) {
          append(diagnostics.consoleMessages, {
            level,
            timestamp: new Date().toISOString(),
            arguments: args.map(serialize)
          });
          return Reflect.apply(original, this, args);
        };
      }

      window.addEventListener('error', (event) => {
        append(diagnostics.pageErrors, {
          type: 'error',
          message: event.message || String(event.error || 'Unknown page error'),
          source: event.filename || null,
          line: event.lineno || null,
          column: event.colno || null,
          stack: event.error?.stack || null
        });
      });
      window.addEventListener('unhandledrejection', (event) => {
        const reason = serialize(event.reason);
        append(diagnostics.pageErrors, {
          type: 'unhandledrejection',
          message: typeof reason === 'string' ? reason : (reason?.message || JSON.stringify(reason)),
          stack: reason?.stack || null
        });
      });
    })();
    """

    private static let audioDiagnosticsBootstrapScript = """
    (() => {
      const diagnostics = window.__VIEWDECK_DIAGNOSTICS__;
      if (!diagnostics || diagnostics.audio) return;

      const audio = {
        mediaEvents: [],
        mediaPlayCalls: [],
        webAudioEvents: [],
        speechEvents: []
      };
      diagnostics.audio = audio;
      const append = (collection, value) => {
        collection.push(value);
        if (collection.length > 200) collection.splice(0, collection.length - 200);
      };
      const timestamp = () => Math.round(performance.now() * 100) / 100;
      const mediaDetails = (element) => ({
        tagName: element?.tagName?.toLowerCase() || null,
        id: element?.id || null,
        currentSrc: element?.currentSrc || element?.src || null,
        currentTime: Number.isFinite(element?.currentTime) ? element.currentTime : null,
        duration: Number.isFinite(element?.duration) ? element.duration : null,
        readyState: element?.readyState ?? null,
        networkState: element?.networkState ?? null,
        paused: element?.paused ?? null,
        ended: element?.ended ?? null,
        error: element?.error ? {
          code: element.error.code,
          message: element.error.message || null
        } : null
      });

      for (const name of [
        'loadstart', 'loadedmetadata', 'canplay', 'play', 'playing',
        'pause', 'ended', 'stalled', 'suspend', 'abort', 'error'
      ]) {
        document.addEventListener(name, (event) => {
          if (!(event.target instanceof HTMLMediaElement)) return;
          append(audio.mediaEvents, {
            type: name,
            atMilliseconds: timestamp(),
            media: mediaDetails(event.target)
          });
        }, true);
      }

      const mediaPlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function(...args) {
        append(audio.mediaPlayCalls, {
          atMilliseconds: timestamp(),
          media: mediaDetails(this)
        });
        return Reflect.apply(mediaPlay, this, args);
      };

      const contextPrototype = window.AudioContext?.prototype ||
        window.webkitAudioContext?.prototype;
      if (contextPrototype && typeof contextPrototype.resume === 'function') {
        const resume = contextPrototype.resume;
        contextPrototype.resume = function(...args) {
          append(audio.webAudioEvents, {
            type: 'context-resume',
            atMilliseconds: timestamp(),
            state: this.state,
            currentTime: this.currentTime
          });
          return Reflect.apply(resume, this, args);
        };
      }

      const sourcePrototype = window.AudioScheduledSourceNode?.prototype;
      if (sourcePrototype && typeof sourcePrototype.start === 'function') {
        const start = sourcePrototype.start;
        sourcePrototype.start = function(...args) {
          append(audio.webAudioEvents, {
            type: 'source-start',
            atMilliseconds: timestamp(),
            nodeType: this.constructor?.name || 'AudioScheduledSourceNode',
            contextState: this.context?.state || null,
            contextTime: this.context?.currentTime ?? null,
            when: args[0] ?? 0
          });
          return Reflect.apply(start, this, args);
        };
      }

      const speechPrototype = window.SpeechSynthesis?.prototype;
      if (speechPrototype && typeof speechPrototype.speak === 'function') {
        const speak = speechPrototype.speak;
        speechPrototype.speak = function(utterance) {
          append(audio.speechEvents, {
            type: 'speak',
            atMilliseconds: timestamp(),
            textLength: utterance?.text?.length ?? 0,
            lang: utterance?.lang || null
          });
          return Reflect.apply(speak, this, arguments);
        };
      }
    })();
    """

    private static let auditScript = """
    (() => {
      const root = document.documentElement;
      const body = document.body;
      const diagnostics = window.__VIEWDECK_DIAGNOSTICS__ || {
        consoleMessages: [],
        pageErrors: []
      };
      let safeArea = { top: 0, right: 0, bottom: 0, left: 0 };
      try {
        safeArea = JSON.parse(root?.dataset?.viewdeckSafeArea || '{}');
      } catch {}
      for (const edge of ['top', 'right', 'bottom', 'left']) {
        safeArea[edge] = Number(safeArea[edge]) || 0;
      }

      const selectorFor = (element) => {
        if (!(element instanceof Element)) return null;
        if (element.id) return '#' + CSS.escape(element.id);
        const parts = [];
        let current = element;
        while (current && current !== body && parts.length < 4) {
          let part = current.localName || current.tagName.toLowerCase();
          const usefulClass = Array.from(current.classList || [])
            .find((name) => name && !/^[a-zA-Z_-]*\\d{4,}/.test(name));
          if (usefulClass) part += '.' + CSS.escape(usefulClass);
          const parent = current.parentElement;
          if (parent) {
            const siblings = Array.from(parent.children).filter((candidate) =>
              candidate.localName === current.localName
            );
            if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
          }
          parts.unshift(part);
          current = parent;
        }
        return parts.join(' > ');
      };
      const rectJSON = (rect) => ({
        x: Math.round(rect.x * 100) / 100,
        y: Math.round(rect.y * 100) / 100,
        width: Math.round(rect.width * 100) / 100,
        height: Math.round(rect.height * 100) / 100,
        right: Math.round(rect.right * 100) / 100,
        bottom: Math.round(rect.bottom * 100) / 100
      });
      const isVisible = (element, rect) => {
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 &&
          style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity || 1) > 0;
      };

      const viewport = {
        width: window.innerWidth,
        height: window.innerHeight,
        devicePixelRatio: window.devicePixelRatio
      };
      const issues = [];
      const scrollWidth = Math.max(root?.scrollWidth || 0, body?.scrollWidth || 0);
      const scrollHeight = Math.max(root?.scrollHeight || 0, body?.scrollHeight || 0);
      if (scrollWidth > viewport.width + 1) {
        issues.push({
          code: 'horizontal-overflow',
          severity: 'warning',
          message: `Document is ${Math.ceil(scrollWidth - viewport.width)} CSS pixels wider than the viewport.`,
          overflowRight: Math.ceil(scrollWidth - viewport.width)
        });
      }

      const overflowElements = [];
      for (const element of Array.from(document.querySelectorAll('body *'))) {
        if (overflowElements.length >= 25) break;
        const rect = element.getBoundingClientRect();
        if (!isVisible(element, rect)) continue;
        if (rect.left < -1 || rect.right > viewport.width + 1) {
          overflowElements.push({
            selector: selectorFor(element),
            rect: rectJSON(rect),
            overflowLeft: Math.max(0, Math.ceil(-rect.left)),
            overflowRight: Math.max(0, Math.ceil(rect.right - viewport.width))
          });
        }
      }
      if (overflowElements.length) {
        issues.push({
          code: 'elements-outside-viewport',
          severity: 'warning',
          message: `${overflowElements.length} visible element(s) extend beyond the horizontal viewport.`,
          elements: overflowElements
        });
      }

      const interactiveSelector =
        'a[href],button,input,select,textarea,[role="button"],[role="link"],[tabindex]';
      const unsafeInteractiveElements = [];
      const offscreenInteractiveElements = [];
      for (const element of Array.from(document.querySelectorAll(interactiveSelector))) {
        const rect = element.getBoundingClientRect();
        if (!isVisible(element, rect)) continue;
        const selector = selectorFor(element);
        if (rect.right <= 0 || rect.bottom <= 0 ||
            rect.left >= viewport.width || rect.top >= viewport.height) {
          if (offscreenInteractiveElements.length < 25) {
            offscreenInteractiveElements.push({ selector, rect: rectJSON(rect) });
          }
          continue;
        }
        const edges = [];
        if (safeArea.top > 0 && rect.top < safeArea.top) edges.push('top');
        if (safeArea.right > 0 && rect.right > viewport.width - safeArea.right) edges.push('right');
        if (safeArea.bottom > 0 && rect.bottom > viewport.height - safeArea.bottom) edges.push('bottom');
        if (safeArea.left > 0 && rect.left < safeArea.left) edges.push('left');
        if (edges.length && unsafeInteractiveElements.length < 25) {
          unsafeInteractiveElements.push({ selector, edges, rect: rectJSON(rect) });
        }
      }
      if (unsafeInteractiveElements.length) {
        issues.push({
          code: 'interactive-safe-area-overlap',
          severity: 'warning',
          message: `${unsafeInteractiveElements.length} interactive element(s) overlap the simulated safe area.`,
          elements: unsafeInteractiveElements
        });
      }
      if (offscreenInteractiveElements.length) {
        issues.push({
          code: 'interactive-outside-viewport',
          severity: 'warning',
          message: `${offscreenInteractiveElements.length} interactive element(s) are outside the viewport.`,
          elements: offscreenInteractiveElements
        });
      }

      const canvases = Array.from(document.querySelectorAll('canvas')).map((canvas) => {
        const rect = canvas.getBoundingClientRect();
        return {
          selector: selectorFor(canvas),
          rect: rectJSON(rect),
          backingWidth: canvas.width,
          backingHeight: canvas.height
        };
      });
      const mediaElements = Array.from(document.querySelectorAll('audio,video')).map((element) => ({
        selector: selectorFor(element),
        tagName: element.tagName.toLowerCase(),
        currentSrc: element.currentSrc || element.src || null,
        currentTime: Number.isFinite(element.currentTime) ? element.currentTime : null,
        duration: Number.isFinite(element.duration) ? element.duration : null,
        readyState: element.readyState,
        networkState: element.networkState,
        paused: element.paused,
        ended: element.ended,
        muted: element.muted,
        volume: element.volume,
        error: element.error ? {
          code: element.error.code,
          message: element.error.message || null
        } : null
      }));
      return JSON.stringify({
        title: document.title || null,
        url: location.href,
        readyState: document.readyState,
        viewport,
        document: { scrollWidth, scrollHeight },
        safeArea,
        issues,
        canvases,
        audio: {
          mediaElements,
          mediaEvents: diagnostics.audio?.mediaEvents || [],
          mediaPlayCalls: diagnostics.audio?.mediaPlayCalls || [],
          webAudioEvents: diagnostics.audio?.webAudioEvents || [],
          speechEvents: diagnostics.audio?.speechEvents || []
        },
        network: diagnostics.network?.snapshot?.() || {
          loading: false,
          progress: 0,
          pendingCount: 0,
          completedCount: 0,
          failedCount: 0,
          resources: []
        },
        consoleMessages: diagnostics.consoleMessages || [],
        pageErrors: diagnostics.pageErrors || []
      });
    })();
    """

    private func json(_ value: Any) -> String {
        if let string = value as? String,
           let data = try? JSONSerialization.data(withJSONObject: [string]),
           let encoded = String(data: data, encoding: .utf8) {
            return String(encoded.dropFirst().dropLast())
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let encoded = String(data: data, encoding: .utf8) else { return "null" }
        return encoded
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        delegate?.previewDidStartLoading()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if PreviewNavigationPolicy.isUnexpectedBlankCompletion(webView.url, requestedURL: currentURL) {
            showNavigationFailure(
                message: "The address could not be loaded.",
                reportMessage: "WebKit replaced the requested URL with a blank page."
            )
        } else if currentURL != nil, let url = webView.url {
            let displayURL = displayURL(for: url)
            currentURL = displayURL
            safariTop.address = displayURL.host?.replacingOccurrences(of: "www.", with: "")
                ?? displayURL.lastPathComponent
            delegate?.previewDidFinishLoading(title: webView.title, url: displayURL)
        } else {
            delegate?.previewDidFinishLoading(title: webView.title, url: nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else { return nil }

        if PreviewNavigationPolicy.shouldOpenInCurrentPreview(url) {
            navigationGeneration &+= 1
            let displayURL = displayURL(for: url)
            currentURL = displayURL
            safariTop.address = displayURL.host?.replacingOccurrences(of: "www.", with: "")
                ?? displayURL.lastPathComponent
            webView.load(navigationAction.request)
        } else {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: Error) {
        guard !PreviewNavigationPolicy.shouldIgnoreFailure(error) else { return }
        showNavigationFailure(
            message: PreviewNavigationPolicy.userMessage(for: error),
            reportMessage: error.localizedDescription
        )
    }
}

private enum PreviewScreenshotError: LocalizedError {
    case renderFailed
    case windowCompositorUnavailable

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            return "ViewDeck could not render the current device into an image."
        case .windowCompositorUnavailable:
            return "ViewDeck could not capture the preview window's compositor surface."
        }
    }
}

private enum PreviewInspectionError: LocalizedError {
    case invalidResult

    var errorDescription: String? {
        "ViewDeck could not decode the page inspection result."
    }
}

private struct PreviewScreenshotLayer {
    var image: NSImage
    var frame: CGRect
    var clipFrame: CGRect?
}

private final class PreviewScreenshotCompositor: FlippedView {
    private let baseImage: NSImage
    private let webLayers: [PreviewScreenshotLayer]
    private let nativeLayers: [PreviewScreenshotLayer]

    init(
        size: CGSize,
        baseImage: NSImage,
        webLayers: [PreviewScreenshotLayer],
        nativeLayers: [PreviewScreenshotLayer]
    ) {
        self.baseImage = baseImage
        self.webLayers = webLayers
        self.nativeLayers = nativeLayers
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        baseImage.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        for layer in webLayers {
            NSGraphicsContext.saveGraphicsState()
            if let clipFrame = layer.clipFrame {
                NSBezierPath(rect: clipFrame).addClip()
            }
            layer.image.draw(
                in: layer.frame,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        for layer in nativeLayers {
            layer.image.draw(
                in: layer.frame,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
    }
}

final class PreviewCanvasView: FlippedView {
    let preview: DevicePreviewView

    init(
        profile: DeviceProfile,
        networkShapingConfiguration: NetworkShapingConfiguration = .disabled
    ) {
        preview = DevicePreviewView(
            profile: profile,
            networkShapingConfiguration: networkShapingConfiguration
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x0d141c).cgColor
        addSubview(preview)
        preview.attach(to: self)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let logical = preview.logicalSize
        guard logical.width > 0, logical.height > 0 else { return }
        let fit = fittedScale()
        let scale = fit
        let displayed = CGSize(width: logical.width * scale, height: logical.height * scale)
        preview.frame = CGRect(
            x: (bounds.width - displayed.width) / 2,
            y: (bounds.height - displayed.height) / 2,
            width: displayed.width,
            height: displayed.height
        )
        preview.bounds = CGRect(origin: .zero, size: logical)
        preview.needsLayout = true
    }

    private func fittedScale() -> CGFloat {
        let logical = preview.logicalSize
        guard logical.width > 0, logical.height > 0 else { return 1 }
        return min(
            max(0.12, (bounds.width - 48) / logical.width),
            max(0.12, (bounds.height - 40) / logical.height),
            1.75
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(hex: 0x0d141c).setFill()
        dirtyRect.fill()
        let grid = NSColor(hex: 0x9ec7e8, alpha: 0.028)
        grid.setStroke()
        let path = NSBezierPath()
        stride(from: CGFloat(0), through: bounds.width, by: 24).forEach { x in
            path.move(to: CGPoint(x: x, y: 0)); path.line(to: CGPoint(x: x, y: bounds.height))
        }
        stride(from: CGFloat(0), through: bounds.height, by: 24).forEach { y in
            path.move(to: CGPoint(x: 0, y: y)); path.line(to: CGPoint(x: bounds.width, y: y))
        }
        path.lineWidth = 0.5
        path.stroke()
    }
}

final class SafariTopView: FlippedView {
    var address = "localhost" { didSet { needsDisplay = true } }
    var compact = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x35393c).setFill(); bounds.fill()
        let textColor = NSColor.white
        let statusFont = NSFont.systemFont(ofSize: compact ? 13 : 16, weight: .semibold)
        let statusAttributes: [NSAttributedString.Key: Any] = [.font: statusFont, .foregroundColor: textColor]
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        (time as NSString).draw(at: CGPoint(x: 20, y: compact ? 8 : 15), withAttributes: statusAttributes)

        let addressHeight: CGFloat = compact ? 34 : 36
        let addressY = bounds.height - addressHeight - (compact ? 7 : 11)
        let field = NSBezierPath(roundedRect: CGRect(x: 10, y: addressY, width: bounds.width - 20, height: addressHeight), xRadius: addressHeight / 2, yRadius: addressHeight / 2)
        NSColor(hex: 0x73787c).setFill(); field.fill()
        let addressAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: compact ? 13 : 16, weight: .medium),
            .foregroundColor: textColor
        ]
        let size = (address as NSString).size(withAttributes: addressAttributes)
        (address as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: addressY + (addressHeight - size.height) / 2), withAttributes: addressAttributes)
        ("✦" as NSString).draw(at: CGPoint(x: 25, y: addressY + 7), withAttributes: addressAttributes)
        ("⇧" as NSString).draw(at: CGPoint(x: bounds.width - 43, y: addressY + 6), withAttributes: addressAttributes)

        let iconAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: textColor]
        ("▮▮▮  ◔  ▯" as NSString).draw(at: CGPoint(x: bounds.width - 102, y: compact ? 8 : 15), withAttributes: iconAttributes)
    }
}

final class SafariBottomView: FlippedView {
    var compact = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x35393c).setFill(); bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: compact ? 18 : 23, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let baseline = compact ? 10 : 15
        let labels = ["‹", "›", "+", "▢", "•••"]
        for (index, label) in labels.enumerated() {
            let x = bounds.width * (CGFloat(index) + 0.55) / 5
            (label as NSString).draw(at: CGPoint(x: x - 10, y: CGFloat(baseline)), withAttributes: attributes)
        }
        let indicator = NSBezierPath(roundedRect: CGRect(x: (bounds.width - 104) / 2, y: bounds.height - 9, width: 104, height: 4), xRadius: 2, yRadius: 2)
        NSColor.white.withAlphaComponent(0.72).setFill(); indicator.fill()
    }
}

final class AppStatusBarView: PassthroughView {
    override func draw(_ dirtyRect: NSRect) {
        let compact = bounds.height < 36
        let font = NSFont.systemFont(ofSize: compact ? 11 : 17, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let y = max(2, (bounds.height - font.capHeight) / 2 - 2)
        (time as NSString).draw(at: CGPoint(x: compact ? 16 : 35, y: y), withAttributes: attributes)

        let iconFont = NSFont.systemFont(ofSize: compact ? 9 : 14, weight: .bold)
        let iconAttributes: [NSAttributedString.Key: Any] = [
            .font: iconFont,
            .foregroundColor: NSColor.white
        ]
        let icons = "▮▮▮  ◔  ▰"
        let iconWidth = (icons as NSString).size(withAttributes: iconAttributes).width
        (icons as NSString).draw(
            at: CGPoint(x: bounds.width - iconWidth - (compact ? 14 : 32), y: y + 1),
            withAttributes: iconAttributes
        )
    }
}

final class SafeAreaOverlayView: PassthroughView {
    var insets = EdgeInsets.zero { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let fill = NSColor(hex: 0xf0bf3a, alpha: 0.11)
        fill.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: insets.top).fill()
        CGRect(x: 0, y: bounds.height - insets.bottom, width: bounds.width, height: insets.bottom).fill()
        CGRect(x: 0, y: 0, width: insets.left, height: bounds.height).fill()
        CGRect(x: bounds.width - insets.right, y: 0, width: insets.right, height: bounds.height).fill()
        let path = NSBezierPath(rect: CGRect(
            x: insets.left,
            y: insets.top,
            width: max(0, bounds.width - insets.left - insets.right),
            height: max(0, bounds.height - insets.top - insets.bottom)
        ))
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.lineWidth = 1
        NSColor(hex: 0xf0bf3a, alpha: 0.72).setStroke()
        path.stroke()
    }
}
