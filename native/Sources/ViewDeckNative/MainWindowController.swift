import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum QAAppError: LocalizedError {
    case unsupportedSchema(Int)
    case missingSource

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "This scenario uses unsupported schema version \(version)."
        case .missingSource:
            return "The scenario does not contain a URL, local file, or project source."
        }
    }
}

final class MainWindowController: NSWindowController, DevicePreviewDelegate, DevServerControllerDelegate, NSSplitViewDelegate {
    private var customSetups: [CustomDeviceSetup]
    private var devices: [DeviceProfile] { BuiltinDevices.all + customSetups.map(\.profile) }
    private var recentlySavedCustomSetupID: String?
    private var selectedCustomIndex: Int? {
        let index = selectedIndex - BuiltinDevices.all.count
        return customSetups.indices.contains(index) ? index : nil
    }
    private var selectedIndex = 0
    private let preferences: ViewDeckPreferences

    private let splitView = NSSplitView()
    private let sidebar = FlippedView()
    private let center = FlippedView()
    private let inspector = FlippedView()
    private let sidebarHeading = NSTextField(labelWithString: "DEVICE LIBRARY")
    private let deviceListStack = NSStackView()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let addressField = NSTextField()
    private let inspectorTabs = DeckSegmentedControl(labels: ["Device", "Server", "Ports", "Network"], trackingMode: .selectOne, target: nil, action: nil)
    private let inspectorScroll = NSScrollView()
    private let inspectorStack = DeckFillStackView()
    private let projectButton = DeckButton(frame: .zero)
    private let serverButton = DeckButton(frame: .zero)
    private let launchModePopup = NSPopUpButton()
    private let scriptPopup = NSPopUpButton()
    private let customCommandField = NSTextField()
    private let serverStatusLabel = NSTextField(labelWithString: "No local project selected")
    private let logView = NSTextView()
    private var logShowsPlaceholder = false
    private let headerLayerPopup = NSPopUpButton()
    private let footerLayerPopup = NSPopUpButton()
    private let leftLayerPopup = NSPopUpButton()
    private let rightLayerPopup = NSPopUpButton()
    private let toolbarModel = DeckToolbarModel()
    private let server = DevServerController()
    private var layerLibrary = HTMLLayerStore.load()
    private var projectFolder: URL?
    private var staticHTMLFile: URL?
    private var launchMode: LocalLaunchMode = .npmScript
    private var activeServerPreviewIdentity: String?
    private var pendingServerPreviewIdentity: String?
    private var localhostProcesses: [LocalhostProcess] = []
    private var localhostScanInProgress = false
    private var localhostScanError: String?
    private var localhostRefreshTimer: Timer?
    private var networkActivityTimer: Timer?
    private var networkActivityRefreshInFlight = false
    private var networkActivitySignature: String?
    private var networkActivitySnapshot = NetworkActivitySnapshot.empty
    private weak var networkStatusValue: NSTextField?
    private weak var networkConnectionsValue: NSTextField?
    private weak var networkActivitySummary: NSTextField?
    private weak var networkActivityProgress: NSProgressIndicator?
    private weak var networkResourceStack: NSStackView?
    private weak var networkReloadButton: NSButton?
    private var sampleHeaderEnabled = false
    private var sampleLeftEnabled = false
    private var sampleRightEnabled = false
    private var headerPath: URL?
    private var footerPath: URL?
    private var leftPath: URL?
    private var rightPath: URL?
    private let sidebarInitialWidth: CGFloat = 250
    private let inspectorInitialWidth: CGFloat = 320
    private let sidebarMinimumWidth: CGFloat = 250
    private let inspectorMinimumWidth: CGFloat = 260
    private let centerMinimumWidth: CGFloat = 520
    private var restoringSplitPositions = false
    private var hasRestoredSplitPositions = false
    private var sidebarMinimumWidthConstraint: NSLayoutConstraint?
    private var screenshotEditors: [ScreenshotEditorWindowController] = []
    private var standaloneVideoRecorder: LivePreviewVideoRecorder?
    private var qaRecorder: QAScenarioRecorder?
    private var pendingQARecording: QARecordingRequest?
    private var qaPlayback: QAPlaybackController?
    private var pendingQAReplay: QAReplayRequest?
    private var replayVideoRecorder: LivePreviewVideoRecorder?
    private var replayVideoFinished = true
    private var replaySummary: QAPlaybackController.ResultSummary?
    private var replayArtifacts: [[String: Any]] = []
    private var replayErrors: [String] = []
    private var replayStartedAt: Date?
    private var pendingQAServerLaunch: QASourceConfiguration?

    private struct QAReplayRequest {
        var scenario: QAScenario
        var scenarioURL: URL
        var speed: Double
        var captureArtifacts: Bool
        var started: Bool
    }

    private struct QARecordingRequest {
        var recorder: QAScenarioRecorder
        var targetURL: URL
        var captureVideo: Bool
    }

    private enum SplitPreferenceKey {
        static let sidebarWidth = "viewdeck.native.sidebar-width"
        static let inspectorWidth = "viewdeck.native.inspector-width"
        static let sidebarCollapsed = "viewdeck.native.sidebar-collapsed"
    }

    private enum LocalLaunchMode: Int, CaseIterable {
        case npmScript
        case staticHTML
        case customCommand

        var title: String {
            switch self {
            case .npmScript: return "NPM script"
            case .staticHTML: return "Static HTML file"
            case .customCommand: return "Custom command"
            }
        }
    }

    private enum InspectorTab: Int {
        case device
        case server
        case ports
        case network
    }

    private var selectedInspectorTab: InspectorTab {
        InspectorTab(rawValue: inspectorTabs.selectedSegment) ?? .device
    }

    private enum ShellMetric: Int {
        case top, right, bottom, left, radius
    }

    private enum SensorMetric: Int {
        case width, height, top
    }

    let canvas: PreviewCanvasView

    init() {
        let preferences = ViewDeckPreferences()
        let initialCustomSetups = CustomDeviceSetupStore.load()
        self.preferences = preferences
        customSetups = initialCustomSetups
        let selectedID = preferences.selectedDeviceID
        let initialDevices = BuiltinDevices.all + initialCustomSetups.map(\.profile)
        selectedIndex = initialDevices.firstIndex(where: { $0.id == selectedID }) ?? 0
        let canvas = PreviewCanvasView(
            profile: initialDevices[selectedIndex],
            networkShapingConfiguration: preferences.networkShapingConfiguration
        )
        canvas.preview.landscape = preferences.isLandscape
        self.canvas = canvas

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1480, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ViewDeck"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = CGSize(width: 1120, height: 700)
        window.backgroundColor = DeckTheme.window
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        super.init(window: window)

        canvas.preview.delegate = self
        server.delegate = self
        configureToolbarModel()
        buildInterface()
        selectDevice(at: selectedIndex)
        restoreSavedProjectFolder()

        let savedAddress = UserDefaults.standard.string(forKey: "viewdeck.native.last-url") ?? "http://localhost:5173"
        addressField.stringValue = savedAddress
        toolbarModel.address = savedAddress
        restoreSavedLayers()
    }

    required init?(coder: NSCoder) { nil }

    func stopServices() {
        localhostRefreshTimer?.invalidate()
        localhostRefreshTimer = nil
        networkActivityTimer?.invalidate()
        networkActivityTimer = nil
        standaloneVideoRecorder?.stop()
        server.stop()
    }

    func toggleSidebar() {
        setSidebarCollapsed(!sidebarIsCollapsed, persist: true)
    }

    private func buildInterface() {
        guard let window else { return }
        let root = FlippedView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DeckTheme.window.cgColor
        window.contentView = root

        let titlebar = DeckTitleBar()
        titlebar.wantsLayer = true
        titlebar.layer?.backgroundColor = DeckTheme.titlebar.cgColor
        titlebar.layer?.borderColor = DeckTheme.line.cgColor
        titlebar.layer?.borderWidth = 1
        titlebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titlebar)

        let title = NSTextField(labelWithString: "ViewDeck \(AppInfo.version)")
        title.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        title.textColor = DeckTheme.muted
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(title)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.arrangesAllSubviews = false
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = DeckTheme.window.cgColor
        root.addSubview(splitView)

        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = DeckTheme.sidebar.cgColor
        sidebar.layer?.borderColor = DeckTheme.line.cgColor
        sidebar.layer?.borderWidth = 1
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        center.translatesAutoresizingMaskIntoConstraints = false
        center.wantsLayer = true
        center.layer?.backgroundColor = DeckTheme.panelRaised.cgColor
        inspector.wantsLayer = true
        inspector.layer?.backgroundColor = DeckTheme.panel.cgColor
        inspector.layer?.borderColor = DeckTheme.line.cgColor
        inspector.layer?.borderWidth = 1
        inspector.translatesAutoresizingMaskIntoConstraints = false

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(center)
        splitView.addArrangedSubview(inspector)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 2)

        let sidebarMinimumWidthConstraint = sidebar.widthAnchor.constraint(
            greaterThanOrEqualToConstant: sidebarMinimumWidth
        )
        self.sidebarMinimumWidthConstraint = sidebarMinimumWidthConstraint
        NSLayoutConstraint.activate([
            sidebarMinimumWidthConstraint,
            sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            center.widthAnchor.constraint(greaterThanOrEqualToConstant: centerMinimumWidth),
            inspector.widthAnchor.constraint(greaterThanOrEqualToConstant: inspectorMinimumWidth),
            inspector.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            titlebar.topAnchor.constraint(equalTo: root.topAnchor),
            titlebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titlebar.heightAnchor.constraint(equalToConstant: 42),
            title.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor),
            splitView.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        buildSidebar()
        buildCenter()
        buildInspector()
        DispatchQueue.main.async { [weak self] in self?.restoreSplitPositions() }
    }

    private func buildSidebar() {
        sidebarHeading.font = .monospacedSystemFont(ofSize: 9.5, weight: .bold)
        sidebarHeading.textColor = DeckTheme.muted
        sidebarHeading.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarHeading)

        deviceListStack.orientation = .vertical
        deviceListStack.alignment = .leading
        deviceListStack.spacing = 4
        deviceListStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(deviceListStack)
        scroll.documentView = document
        sidebar.addSubview(scroll)

        let quickActions = NSHostingView(rootView: DeckQuickActionsView(model: toolbarModel))
        quickActions.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(quickActions)

        projectButton.title = "Choose local project"
        projectButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        projectButton.imagePosition = .imageLeading
        projectButton.imageHugsTitle = true
        projectButton.target = self
        projectButton.action = #selector(chooseProject)
        projectButton.toolTip = "Choose the folder used by the Server tab"
        projectButton.alignment = .left
        projectButton.font = .systemFont(ofSize: 11.5, weight: .semibold)
        styleButton(projectButton, fill: DeckTheme.card, border: DeckTheme.lineStrong, text: DeckTheme.secondaryText, radius: 10)
        projectButton.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(projectButton)

        NSLayoutConstraint.activate([
            sidebarHeading.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 20),
            sidebarHeading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            sidebarHeading.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: sidebarHeading.bottomAnchor, constant: 13),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 7),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -7),
            scroll.bottomAnchor.constraint(equalTo: quickActions.topAnchor, constant: -12),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            deviceListStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            deviceListStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            deviceListStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            deviceListStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            quickActions.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            quickActions.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            quickActions.bottomAnchor.constraint(equalTo: projectButton.topAnchor, constant: -8),
            quickActions.heightAnchor.constraint(equalToConstant: 252),
            projectButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            projectButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            projectButton.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
            projectButton.heightAnchor.constraint(equalToConstant: 50)
        ])
        refreshDeviceLists()
    }

    private func buildCenter() {
        let toolbar = NSHostingView(rootView: DeckToolbarView(model: toolbarModel))
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.zPosition = 20
        center.addSubview(toolbar)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.layer?.zPosition = 0
        center.addSubview(canvas)
        center.addSubview(toolbar, positioned: .above, relativeTo: canvas)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: center.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 58),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: center.bottomAnchor)
        ])
    }

    private func configureToolbarModel() {
        toolbarModel.commitViewport = { [weak self] width, height in
            guard let self else { return }
            self.widthField.doubleValue = width
            self.heightField.doubleValue = height
            self.viewportChanged()
        }
        toolbarModel.changeDPR = { [weak self] value in self?.setDPR(value) }
        toolbarModel.toggleSidebar = { [weak self] in self?.toggleSidebar() }
        toolbarModel.rotate = { [weak self] in self?.rotateDevice() }
        toolbarModel.captureScreenshot = { [weak self] in self?.captureScreenshot() }
        toolbarModel.toggleVideoRecording = { [weak self] in self?.toggleVideoRecording() }
        toolbarModel.toggleQARecording = { [weak self] in self?.toggleQARecording() }
        toolbarModel.addQACheckpoint = { [weak self] in self?.addQACheckpoint() }
        toolbarModel.replayQAScenario = { [weak self] in self?.chooseAndReplayQAScenario() }
        toolbarModel.stopQAReplay = { [weak self] in self?.stopQAReplay() }
        toolbarModel.back = { [weak self] in self?.goBack() }
        toolbarModel.forward = { [weak self] in self?.goForward() }
        toolbarModel.reload = { [weak self] in self?.reloadPreview() }
        toolbarModel.openDeveloperTools = { [weak self] in self?.canvas.preview.showWebInspector() }
        toolbarModel.stopLocalProcess = { [weak self] in self?.stopLocalProcessAndClearPreview() }
        toolbarModel.load = { [weak self] address in
            guard let self else { return }
            self.addressField.stringValue = address
            self.loadPreview()
        }
    }

    private func buildInspector() {
        inspectorTabs.selectedSegment = preferences.inspectorTabIndex(segmentCount: inspectorTabs.segmentCount)
        inspectorTabs.selectionChanged = { [weak self] in
            self?.rebuildInspector()
            self?.updateLocalhostMonitoring()
            self?.updateNetworkMonitoring()
        }
        inspectorTabs.target = self
        inspectorTabs.action = #selector(inspectorTabChanged)
        inspectorTabs.setToolTip("Edit device geometry, orientation, safe areas, and HTML layers", forSegment: 0)
        inspectorTabs.setToolTip("Preview static HTML or run a local command", forSegment: 1)
        inspectorTabs.setToolTip("Inspect processes listening on localhost ports", forSegment: 2)
        inspectorTabs.setToolTip("Simulate deterministic latency and bandwidth", forSegment: 3)
        inspectorTabs.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(inspectorTabs)

        inspectorScroll.drawsBackground = false
        inspectorScroll.hasVerticalScroller = true
        inspectorScroll.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(inspectorScroll)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        inspectorStack.orientation = .vertical
        inspectorStack.alignment = .leading
        inspectorStack.distribution = .fill
        inspectorStack.spacing = 14
        inspectorStack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 24, right: 18)
        inspectorStack.horizontalInset = 36
        inspectorStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(inspectorStack)
        inspectorScroll.documentView = document

        NSLayoutConstraint.activate([
            inspectorTabs.topAnchor.constraint(equalTo: inspector.topAnchor),
            inspectorTabs.leadingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspectorTabs.trailingAnchor.constraint(equalTo: inspector.trailingAnchor),
            inspectorTabs.heightAnchor.constraint(equalToConstant: 54),
            inspectorScroll.topAnchor.constraint(equalTo: inspectorTabs.bottomAnchor),
            inspectorScroll.leadingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspectorScroll.trailingAnchor.constraint(equalTo: inspector.trailingAnchor),
            inspectorScroll.bottomAnchor.constraint(equalTo: inspector.bottomAnchor),
            document.widthAnchor.constraint(equalTo: inspectorScroll.contentView.widthAnchor),
            inspectorStack.topAnchor.constraint(equalTo: document.topAnchor),
            inspectorStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            inspectorStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            inspectorStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        rebuildInspector()
        updateLocalhostMonitoring()
        updateNetworkMonitoring()
    }

    private func rebuildInspector() {
        networkStatusValue = nil
        networkConnectionsValue = nil
        networkActivitySummary = nil
        networkActivityProgress = nil
        networkResourceStack = nil
        networkReloadButton = nil
        inspectorStack.arrangedSubviews.forEach { inspectorStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        switch selectedInspectorTab {
        case .device: buildDeviceInspector()
        case .server: buildServerInspector()
        case .ports: buildPortsInspector()
        case .network: buildNetworkInspector()
        }
    }

    private func buildDeviceInspector() {
        let profile = canvas.preview.profile
        inspectorStack.addArrangedSubview(inspectorHeading(profile.name, subtitle: "Native macOS WKWebView · \(profile.viewport.dpr.formatted())× DPR"))

        inspectorStack.addArrangedSubview(sectionLabel("IDENTITY & ORIENTATION"))
        let name = inspectorTextField(profile.name, action: #selector(inspectorNameChanged(_:)))
        let platform = inspectorPopup(
            values: DevicePlatform.allCases.map(\.rawValue),
            selected: profile.platform.rawValue,
            action: #selector(inspectorPlatformChanged(_:))
        )
        let orientation = DeckSegmentedControl(
            labels: ["Portrait", "Landscape"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(inspectorOrientationChanged(_:))
        )
        orientation.selectedSegment = canvas.preview.landscape ? 1 : 0
        orientation.setToolTip("Use portrait orientation", forSegment: 0)
        orientation.setToolTip("Use landscape orientation", forSegment: 1)
        orientation.translatesAutoresizingMaskIntoConstraints = false
        orientation.widthAnchor.constraint(equalToConstant: 150).isActive = true
        orientation.heightAnchor.constraint(equalToConstant: 34).isActive = true
        inspectorStack.addArrangedSubview(inspectorCard([
            formRow("Name", field: name),
            formRow("Platform", field: platform),
            formRow("Orientation", field: orientation)
        ]))

        inspectorStack.addArrangedSubview(sectionLabel("VIEWPORT"))
        inspectorStack.addArrangedSubview(inspectorCard([
            formRow("Width", field: inspectorNumberField(canvas.preview.logicalViewportSize.width, action: #selector(inspectorWidthChanged))),
            formRow("Height", field: inspectorNumberField(canvas.preview.logicalViewportSize.height, action: #selector(inspectorHeightChanged))),
            formRow("Pixel ratio", field: inspectorNumberField(profile.viewport.dpr, action: #selector(inspectorDPRChanged))),
            cardDivider(),
            infoRow("Content viewport", value: "\(Int(canvas.preview.contentViewportSize.width)) × \(Int(canvas.preview.contentViewportSize.height))"),
            infoRow("Physical pixels", value: "\(Int(canvas.preview.logicalViewportSize.width * profile.viewport.dpr)) × \(Int(canvas.preview.logicalViewportSize.height * profile.viewport.dpr))"),
            infoRow("Rendering engine", value: "Apple WebKit")
        ]))

        inspectorStack.addArrangedSubview(sectionLabel("DEVICE SKIN"))
        let shellValues: [(String, ShellMetric, CGFloat)] = [
            ("Shell top", .top, profile.shell.top),
            ("Shell right", .right, profile.shell.right),
            ("Shell bottom", .bottom, profile.shell.bottom),
            ("Shell left", .left, profile.shell.left),
            ("Corner radius", .radius, profile.shell.radius)
        ]
        let shellRows = shellValues.map { label, metric, value in
            let field = inspectorNumberField(value, action: #selector(inspectorShellChanged(_:)))
            field.tag = metric.rawValue
            return formRow(label, field: field)
        }
        inspectorStack.addArrangedSubview(inspectorCard(shellRows))

        inspectorStack.addArrangedSubview(sectionLabel("SENSOR & SYSTEM UI"))
        var sensorRows: [NSView] = [
            formRow(
                "Sensor type",
                field: inspectorPopup(
                    values: SensorType.allCases.map(\.rawValue),
                    selected: profile.sensor.type.rawValue,
                    action: #selector(inspectorSensorTypeChanged(_:))
                )
            )
        ]
        let sensorValues: [(String, SensorMetric, CGFloat)] = [
            ("Sensor width", .width, profile.sensor.width),
            ("Sensor height", .height, profile.sensor.height),
            ("Sensor top", .top, profile.sensor.top)
        ]
        sensorRows += sensorValues.map { label, metric, value in
            let field = inspectorNumberField(value, action: #selector(inspectorSensorChanged(_:)))
            field.tag = metric.rawValue
            return formRow(label, field: field)
        }
        let homeIndicator = DeckCheckboxButton(
            title: "Home indicator",
            target: self,
            action: #selector(inspectorHomeIndicatorChanged(_:))
        )
        homeIndicator.state = profile.homeIndicator ? .on : .off
        homeIndicator.toolTip = "Show the simulated home indicator when Safari chrome is hidden"
        sensorRows += [cardDivider(), homeIndicator]
        inspectorStack.addArrangedSubview(inspectorCard(sensorRows))

        appendSafeAreaControls()
        appendLayerControls()

        inspectorStack.addArrangedSubview(sectionLabel("BROWSER SIMULATION"))
        let safari = DeckCheckboxButton(title: "iOS Safari interface", target: self, action: #selector(toggleSafari(_:)))
        safari.state = profile.safariChrome ? .on : .off
        safari.toolTip = "Reserve the measured Safari areas above and below the page."
        inspectorStack.addArrangedSubview(inspectorCard([
            safari,
            helpText("Reserves the measured Safari address and navigation bars around the website viewport.")
        ]))

        if let customIndex = selectedCustomIndex {
            let setupID = customSetups[customIndex].id
            let didJustSave = recentlySavedCustomSetupID == setupID
            let save = makeWideButton(
                didJustSave ? "Device changes saved" : "Save device changes",
                action: #selector(saveSelectedCustomSetup)
            )
            save.toolTip = didJustSave
                ? "The complete custom setup was saved"
                : "Save the current profile, orientation, and active layers"
            save.image = NSImage(
                systemSymbolName: didJustSave ? "checkmark.circle.fill" : "square.and.arrow.down",
                accessibilityDescription: nil
            )
            save.imagePosition = .imageLeading
            inspectorStack.addArrangedSubview(save)
        } else {
            let add = makeWideButton(
                "Add to custom devices",
                action: #selector(addCurrentDeviceToCustom)
            )
            add.toolTip = "Save this edited device, its orientation, and active layers"
            add.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
            add.imagePosition = .imageLeading
            inspectorStack.addArrangedSubview(add)
        }
    }

    private func appendSafeAreaControls() {
        let safe = canvas.preview.safeArea
        var geometryRows: [NSView] = []
        [("Top", safe.top), ("Right", safe.right), ("Bottom", safe.bottom), ("Left", safe.left)]
            .enumerated()
            .forEach { index, item in
                let field = inspectorNumberField(item.1, action: #selector(safeAreaChanged))
                field.tag = index
                geometryRows.append(formRow(item.0, field: field))
            }
        inspectorStack.addArrangedSubview(sectionLabel("SAFE AREA INSETS"))
        inspectorStack.addArrangedSubview(inspectorCard(geometryRows))

        inspectorStack.addArrangedSubview(sectionLabel("SAFE AREA BEHAVIOR"))
        let visible = DeckCheckboxButton(title: "Show safe-area guide", target: self, action: #selector(showSafeAreaChanged))
        visible.state = canvas.preview.showSafeArea ? .on : .off
        visible.toolTip = "Show or hide the visual guide; this does not change the website layout"
        let apply = DeckCheckboxButton(title: "Force page inside safe area", target: self, action: #selector(applySafeAreaChanged))
        apply.state = canvas.preview.applySafeAreaToPage ? .on : .off
        apply.toolTip = "Tell WebKit which parts of the viewport are obscured by the simulated device"
        inspectorStack.addArrangedSubview(inspectorCard([
            visible,
            apply,
            cardDivider(),
            helpText("The guide is visual only. Leave Force page inside safe area off for a full-bleed game; turn it on to make WebKit shrink and adjust page layout around both obscured edges.")
        ]))
    }

    private func buildNetworkInspector() {
        let configuration = canvas.preview.networkShapingConfiguration
        inspectorStack.addArrangedSubview(inspectorHeading(
            "Network shaping",
            subtitle: "Deterministic TCP conditions for the primary page"
        ))

        let enabled = DeckCheckboxButton(
            title: "Enable network shaping",
            target: self,
            action: #selector(networkShapingEnabledChanged(_:))
        )
        enabled.state = configuration.enabled ? .on : .off
        let offline = DeckCheckboxButton(
            title: "Offline",
            target: self,
            action: #selector(networkShapingOfflineChanged(_:))
        )
        offline.state = configuration.offline ? .on : .off
        let report = canvas.preview.networkShapingReport()
        let activeConnections = report["activeConnectionCount"] as? Int ?? 0
        let acceptedConnections = report["acceptedConnectionCount"] as? Int ?? 0
        let statusValue = inspectorInfoField(canvas.preview.networkShapingStatus)
        let connectionsValue = inspectorInfoField(
            "\(activeConnections) active · \(acceptedConnections) total"
        )
        networkStatusValue = statusValue
        networkConnectionsValue = connectionsValue
        inspectorStack.addArrangedSubview(sectionLabel("STATE"))
        inspectorStack.addArrangedSubview(inspectorCard([
            enabled,
            offline,
            cardDivider(),
            formRow("Status", field: statusValue),
            formRow("Connections", field: connectionsValue)
        ]))

        let values: [(String, Double)] = [
            ("Round-trip latency", configuration.roundTripTimeMilliseconds),
            ("Jitter (± ms)", configuration.jitterMilliseconds),
            ("Download (Kbps)", configuration.downloadKilobitsPerSecond),
            ("Upload (Kbps)", configuration.uploadKilobitsPerSecond),
            ("Seed", Double(configuration.seed))
        ]
        let rows = values.enumerated().map { index, value in
            let field = inspectorNumberField(
                CGFloat(value.1),
                action: #selector(networkShapingValueChanged(_:))
            )
            field.cell?.sendsActionOnEndEditing = true
            field.tag = index
            return formRow(value.0, field: field)
        }
        inspectorStack.addArrangedSubview(sectionLabel("CONDITIONS"))
        inspectorStack.addArrangedSubview(inspectorCard(rows + [
            cardDivider(),
            helpText("RTT is split across both directions. Jitter is deterministic for a seed. Set a bandwidth value to 0 for unlimited throughput.")
        ]))

        let reload = makeWideButton(
            "Reload from origin with these conditions",
            action: #selector(reloadPreviewFromOrigin)
        )
        reload.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        reload.imagePosition = .imageLeading
        reload.isEnabled = canvas.preview.currentURL != nil
        networkReloadButton = reload
        inspectorStack.addArrangedSubview(reload)

        let activitySummary = helpText("No page resources observed yet.")
        let activityProgress = NSProgressIndicator()
        activityProgress.style = .bar
        activityProgress.minValue = 0
        activityProgress.maxValue = 1
        activityProgress.translatesAutoresizingMaskIntoConstraints = false
        activityProgress.heightAnchor.constraint(equalToConstant: 7).isActive = true
        activityProgress.setAccessibilityLabel("Known resource loading progress")
        let resourceStack = NSStackView()
        resourceStack.orientation = .vertical
        resourceStack.alignment = .leading
        resourceStack.spacing = 8
        resourceStack.translatesAutoresizingMaskIntoConstraints = false
        networkActivitySummary = activitySummary
        networkActivityProgress = activityProgress
        networkResourceStack = resourceStack
        inspectorStack.addArrangedSubview(sectionLabel("RESOURCE ACTIVITY"))
        inspectorStack.addArrangedSubview(inspectorCard([
            activitySummary,
            activityProgress,
            cardDivider(),
            resourceStack
        ], spacing: 8))
        inspectorStack.addArrangedSubview(helpText(
            "Pending bars are indeterminate because WebKit exposes resource size only after completion. A SOCKSv5 proxy shapes remote TCP traffic without decrypting HTTPS. Local HTTP uses an internal loopback bridge. Cached resources and HTTP/3/QUIC are not shaped."
        ))
        renderNetworkActivity(networkActivitySnapshot)
    }

    private func appendLayerControls() {
        inspectorStack.addArrangedSubview(sectionLabel("PAGE LAYERS · HEADER"))
        configureLayerPopup(headerLayerPopup, kind: .header, action: #selector(headerLayerSelected(_:)))
        let importHeader = makeWideButton("Import header HTML…", action: #selector(chooseHeader))
        importHeader.toolTip = "Import an existing HTML file into the header library"
        importHeader.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        importHeader.imagePosition = .imageLeading
        let editHeader = makeWideButton(
            sampleHeaderEnabled || headerPath != nil ? "Edit header HTML…" : "Create header HTML…",
            action: #selector(editHeaderLayer)
        )
        editHeader.toolTip = "Create or edit the selected reusable header HTML"
        editHeader.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        editHeader.imagePosition = .imageLeading
        inspectorStack.addArrangedSubview(inspectorCard([
            headerLayerPopup,
            importHeader,
            editHeader,
            formRow("Reserved height", field: inspectorNumberField(canvas.preview.headerHeight, action: #selector(headerHeightChanged)))
        ]))
        inspectorStack.addArrangedSubview(sectionLabel("PAGE LAYERS · FOOTER"))
        configureLayerPopup(footerLayerPopup, kind: .footer, action: #selector(footerLayerSelected(_:)))
        let importFooter = makeWideButton("Import footer HTML…", action: #selector(chooseFooter))
        importFooter.toolTip = "Import an existing HTML file into the footer library"
        importFooter.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        importFooter.imagePosition = .imageLeading
        let editFooter = makeWideButton(
            footerPath != nil ? "Edit footer HTML…" : "Create footer HTML…",
            action: #selector(editFooterLayer)
        )
        editFooter.toolTip = "Create or edit the selected reusable footer HTML"
        editFooter.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        editFooter.imagePosition = .imageLeading
        inspectorStack.addArrangedSubview(inspectorCard([
            footerLayerPopup,
            importFooter,
            editFooter,
            formRow("Reserved height", field: inspectorNumberField(canvas.preview.footerHeight, action: #selector(footerHeightChanged)))
        ]))
        inspectorStack.addArrangedSubview(sectionLabel("PAGE LAYERS · LANDSCAPE LEFT"))
        configureLayerPopup(leftLayerPopup, kind: .left, action: #selector(leftLayerSelected(_:)))
        let importLeft = makeWideButton("Import left rail HTML…", action: #selector(chooseLeft))
        importLeft.toolTip = "Import an existing HTML file into the left rail library"
        importLeft.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        importLeft.imagePosition = .imageLeading
        let editLeft = makeWideButton(
            sampleLeftEnabled || leftPath != nil ? "Edit left rail HTML…" : "Create left rail HTML…",
            action: #selector(editLeftLayer)
        )
        editLeft.toolTip = "Create or edit the selected reusable left rail HTML"
        editLeft.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        editLeft.imagePosition = .imageLeading
        inspectorStack.addArrangedSubview(inspectorCard([
            leftLayerPopup,
            importLeft,
            editLeft,
            formRow("Reserved width", field: inspectorNumberField(canvas.preview.leftWidth, action: #selector(leftWidthChanged)))
        ]))
        inspectorStack.addArrangedSubview(sectionLabel("PAGE LAYERS · LANDSCAPE RIGHT"))
        configureLayerPopup(rightLayerPopup, kind: .right, action: #selector(rightLayerSelected(_:)))
        let importRight = makeWideButton("Import right rail HTML…", action: #selector(chooseRight))
        importRight.toolTip = "Import an existing HTML file into the right rail library"
        importRight.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        importRight.imagePosition = .imageLeading
        let editRight = makeWideButton(
            sampleRightEnabled || rightPath != nil ? "Edit right rail HTML…" : "Create right rail HTML…",
            action: #selector(editRightLayer)
        )
        editRight.toolTip = "Create or edit the selected reusable right rail HTML"
        editRight.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        editRight.imagePosition = .imageLeading
        inspectorStack.addArrangedSubview(inspectorCard([
            rightLayerPopup,
            importRight,
            editRight,
            formRow("Reserved width", field: inspectorNumberField(canvas.preview.rightWidth, action: #selector(rightWidthChanged)))
        ]))
        let clear = makeWideButton("Clear active layers", action: #selector(clearLayers))
        clear.toolTip = "Remove every active page layer from the preview"
        clear.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        clear.imagePosition = .imageLeading
        inspectorStack.addArrangedSubview(clear)
        inspectorStack.addArrangedSubview(helpText("Left and right rails reserve page width only in landscape. Imported files stay in this library for reuse, reload from disk when selected, and run in isolated WKWebViews."))
    }

    private func buildServerInspector() {
        inspectorStack.addArrangedSubview(inspectorHeading("Local preview", subtitle: "Open an HTML file or run any project command"))
        projectButton.title = projectFolder == nil ? "Choose local project" : projectFolder!.lastPathComponent
        let choose = makeWideButton(projectFolder == nil ? "Choose project folder…" : projectFolder!.path, action: #selector(chooseProject))
        choose.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        choose.imagePosition = .imageLeading
        choose.toolTip = "Choose the working folder for scripts and custom commands"
        inspectorStack.addArrangedSubview(choose)
        let openTerminal = makeWideButton("Open terminal at project", action: #selector(openTerminalForSelectedProject))
        openTerminal.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        openTerminal.imagePosition = .imageLeading
        if let projectFolder {
            openTerminal.toolTip = "Open Terminal in \(projectFolder.path)"
            openTerminal.isEnabled = true
        } else {
            openTerminal.toolTip = "Choose a local project first"
            openTerminal.isEnabled = false
        }
        inspectorStack.addArrangedSubview(openTerminal)

        inspectorStack.addArrangedSubview(sectionLabel("LAUNCH MODE"))
        if launchModePopup.itemArray.isEmpty {
            launchModePopup.addItems(withTitles: LocalLaunchMode.allCases.map(\.title))
            launchModePopup.target = self
            launchModePopup.action = #selector(launchModeChanged(_:))
            launchModePopup.translatesAutoresizingMaskIntoConstraints = false
            launchModePopup.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }
        launchModePopup.selectItem(at: launchMode.rawValue)
        launchModePopup.toolTip = "Choose how this project should be previewed"
        configureDeckPopup(launchModePopup)
        inspectorStack.addArrangedSubview(launchModePopup)

        if scriptPopup.translatesAutoresizingMaskIntoConstraints {
            scriptPopup.translatesAutoresizingMaskIntoConstraints = false
            scriptPopup.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }
        if scriptPopup.itemArray.isEmpty {
            scriptPopup.addItem(withTitle: projectFolder == nil ? "Select a project first" : "No npm scripts found")
        }
        scriptPopup.isEnabled = projectFolder != nil && scriptPopup.titleOfSelectedItem != "No npm scripts found"
        scriptPopup.toolTip = "Choose a script from package.json"
        configureDeckPopup(scriptPopup)

        if customCommandField.translatesAutoresizingMaskIntoConstraints {
            customCommandField.placeholderString = "e.g. pnpm dev --host 127.0.0.1"
            customCommandField.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
            customCommandField.target = self
            customCommandField.action = #selector(customCommandSubmitted)
            customCommandField.translatesAutoresizingMaskIntoConstraints = false
            customCommandField.heightAnchor.constraint(equalToConstant: 36).isActive = true
            configureDeckField(customCommandField)
        }
        customCommandField.toolTip = "Enter the command to run in the selected project folder"

        serverButton.target = self
        serverButton.action = #selector(toggleServer)
        let serverIsActive = server.state == .running || server.state == .starting
        let serverIsStopping = server.state == .stopping
        switch launchMode {
        case .npmScript:
            serverButton.title = serverIsActive ? "Stop process" : "Run npm script"
            serverButton.toolTip = serverIsActive ? "Stop the running npm process" : "Run the selected package.json script"
        case .staticHTML:
            serverButton.title = "Preview HTML file"
            serverButton.toolTip = "Load the selected HTML file directly in WKWebView"
        case .customCommand:
            serverButton.title = serverIsActive ? "Stop process" : "Run custom command"
            serverButton.toolTip = serverIsActive ? "Stop the running custom process" : "Run this command in the selected folder"
        }
        if serverIsStopping {
            serverButton.title = "Stopping process…"
            serverButton.toolTip = "Wait for the previous process to release its port"
        }
        serverButton.isEnabled = !serverIsStopping
        serverButton.image = NSImage(
            systemSymbolName: serverIsStopping
                ? "hourglass"
                : serverIsActive ? "stop.circle.fill" : launchMode == .staticHTML ? "doc.text.magnifyingglass" : "play.fill",
            accessibilityDescription: nil
        )
        serverButton.imagePosition = .imageLeading
        serverButton.imageHugsTitle = true
        serverButton.alignment = .center
        serverButton.font = .systemFont(ofSize: 11.5, weight: .semibold)
        styleButton(
            serverButton,
            fill: serverIsActive ? NSColor(hex: 0xff5c57, alpha: 0.10) : DeckTheme.accentSoft,
            border: serverIsActive ? NSColor(hex: 0xff6f69, alpha: 0.38) : DeckTheme.accentLine,
            text: serverIsActive ? DeckTheme.danger : DeckTheme.accentBright,
            radius: 9
        )
        if serverButton.translatesAutoresizingMaskIntoConstraints {
            serverButton.translatesAutoresizingMaskIntoConstraints = false
            serverButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
        serverStatusLabel.textColor = server.state == .running ? NSColor(hex: 0xb9f45c) : NSColor(hex: 0x8a949d)
        serverStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        serverStatusLabel.maximumNumberOfLines = 2
        serverStatusLabel.lineBreakMode = .byWordWrapping
        if serverStatusLabel.translatesAutoresizingMaskIntoConstraints {
            serverStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        }
        var launchControls: [NSView] = []
        switch launchMode {
        case .npmScript:
            launchControls.append(scriptPopup)
        case .staticHTML:
            let fileTitle = staticHTMLFile?.path ?? "Choose an HTML file…"
            let file = makeWideButton(fileTitle, action: #selector(chooseStaticHTML))
            file.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            file.imagePosition = .imageLeading
            file.toolTip = "Choose an HTML file and allow it to read neighboring assets"
            launchControls.append(file)
        case .customCommand:
            launchControls.append(customCommandField)
        }
        launchControls.append(serverButton)
        launchControls.append(serverStatusLabel)
        inspectorStack.addArrangedSubview(inspectorCard(launchControls))
        inspectorStack.addArrangedSubview(sectionLabel("OUTPUT"))
        logView.isEditable = false
        logView.drawsBackground = true
        logView.backgroundColor = NSColor(hex: 0x080b0d)
        logView.textColor = NSColor(hex: 0x9ba5ad)
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.textContainerInset = NSSize(width: 10, height: 10)
        if logView.string.isEmpty {
            logView.string = "Process output will appear here."
            logView.textColor = DeckTheme.dim
            logShowsPlaceholder = true
        }
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        logScroll.translatesAutoresizingMaskIntoConstraints = false

        let logContainer = FlippedView()
        logContainer.wantsLayer = true
        logContainer.layer?.backgroundColor = NSColor(hex: 0x080b0d).cgColor
        logContainer.layer?.cornerRadius = 10
        logContainer.layer?.borderColor = DeckTheme.lineStrong.cgColor
        logContainer.layer?.borderWidth = 1
        logContainer.translatesAutoresizingMaskIntoConstraints = false
        logContainer.setContentCompressionResistancePriority(.required, for: .vertical)
        logContainer.addSubview(logScroll)
        let outputHeight = max(240, inspectorScroll.contentView.bounds.height - 315)
        NSLayoutConstraint.activate([
            logScroll.topAnchor.constraint(equalTo: logContainer.topAnchor, constant: 1),
            logScroll.leadingAnchor.constraint(equalTo: logContainer.leadingAnchor, constant: 1),
            logScroll.trailingAnchor.constraint(equalTo: logContainer.trailingAnchor, constant: -1),
            logScroll.bottomAnchor.constraint(equalTo: logContainer.bottomAnchor, constant: -1),
            logContainer.heightAnchor.constraint(equalToConstant: outputHeight)
        ])
        inspectorStack.addArrangedSubview(logContainer)
    }

    private func buildPortsInspector() {
        inspectorStack.addArrangedSubview(inspectorHeading(
            "Localhost ports",
            subtitle: "Processes currently listening for connections on this Mac"
        ))

        let refresh = makeWideButton(
            localhostScanInProgress ? "Refreshing listeners…" : "Refresh listeners",
            action: #selector(refreshLocalhostPorts)
        )
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.imagePosition = .imageLeading
        refresh.isEnabled = !localhostScanInProgress
        refresh.toolTip = "Scan listening TCP ports and their owning processes"
        inspectorStack.addArrangedSubview(refresh)

        if let localhostScanError {
            let error = helpText(localhostScanError)
            error.textColor = DeckTheme.danger
            inspectorStack.addArrangedSubview(inspectorCard([error]))
        }

        let collisions = LocalhostPortScanner.collidingPorts(in: localhostProcesses)
        if !collisions.isEmpty {
            let ports = collisions.sorted().map(String.init).joined(separator: ", ")
            let warning = helpText("Port collision detected on \(ports). More than one process is listening, so localhost may open the wrong project.")
            warning.textColor = DeckTheme.danger
            inspectorStack.addArrangedSubview(sectionLabel("COLLISIONS"))
            inspectorStack.addArrangedSubview(inspectorCard([warning]))
        }

        let developmentServers = localhostProcesses.filter(\.isDevelopmentServer)
        let otherListeners = localhostProcesses.filter { !$0.isDevelopmentServer }
        addLocalhostProcessSection(
            title: "DEVELOPMENT SERVERS",
            processes: developmentServers,
            collisions: collisions,
            emptyMessage: localhostScanInProgress ? "Scanning for development servers…" : "No development servers detected."
        )
        addLocalhostProcessSection(
            title: "OTHER LISTENERS",
            processes: otherListeners,
            collisions: collisions,
            emptyMessage: localhostScanInProgress ? "Scanning other listeners…" : "No other listeners detected."
        )
    }

    private func addLocalhostProcessSection(
        title: String,
        processes: [LocalhostProcess],
        collisions: Set<Int>,
        emptyMessage: String
    ) {
        inspectorStack.addArrangedSubview(sectionLabel(title))
        guard !processes.isEmpty else {
            inspectorStack.addArrangedSubview(inspectorCard([helpText(emptyMessage)]))
            return
        }
        for process in processes {
            inspectorStack.addArrangedSubview(localhostProcessCard(process, collisions: collisions))
        }
    }

    private func localhostProcessCard(_ process: LocalhostProcess, collisions: Set<Int>) -> NSView {
        let title = NSTextField(labelWithString: "\(process.displayName)   PID \(process.pid)")
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = process.isDevelopmentServer ? DeckTheme.accentBright : DeckTheme.text
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let endpoints = process.endpoints.map(\.label).joined(separator: "  ·  ")
        let endpointLabel = NSTextField(wrappingLabelWithString: endpoints)
        endpointLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        endpointLabel.textColor = process.ports.contains(where: collisions.contains)
            ? DeckTheme.danger
            : DeckTheme.secondaryText
        endpointLabel.translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = [title, endpointLabel]
        if let workingDirectory = process.workingDirectory, !workingDirectory.isEmpty {
            let folder = helpText(workingDirectory)
            folder.lineBreakMode = .byTruncatingMiddle
            folder.toolTip = workingDirectory
            views.append(folder)
        }
        let command = helpText(process.command)
        command.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        command.lineBreakMode = .byTruncatingMiddle
        command.toolTip = process.command
        views.append(command)

        let safePorts = process.ports.filter { !collisions.contains($0) }
        if process.isDevelopmentServer, safePorts.count == 1, let port = safePorts.first {
            let open = makeWideButton("Open localhost:\(port)", action: #selector(openLocalhostPort(_:)))
            open.tag = port
            open.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
            open.imagePosition = .imageLeading
            open.toolTip = "Load http://localhost:\(port)/ in the preview"
            views.append(open)
        } else if process.ports.contains(where: collisions.contains) {
            let collision = helpText("Resolve the collision before opening this port.")
            collision.textColor = DeckTheme.danger
            views.append(collision)
        }
        if process.isDevelopmentServer {
            let stop = makeWideButton("Stop PID \(process.pid)", action: #selector(stopLocalhostProcess(_:)))
            stop.tag = Int(process.pid)
            stop.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
            stop.imagePosition = .imageLeading
            stop.toolTip = "Terminate this development server after confirmation"
            styleButton(
                stop,
                fill: NSColor(hex: 0xff5c57, alpha: 0.08),
                border: NSColor(hex: 0xff6f69, alpha: 0.32),
                text: DeckTheme.danger,
                radius: 9
            )
            views.append(stop)
        }
        return inspectorCard(views, spacing: 7)
    }

    private func updateLocalhostMonitoring() {
        guard selectedInspectorTab == .ports else {
            localhostRefreshTimer?.invalidate()
            localhostRefreshTimer = nil
            return
        }
        if localhostRefreshTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.refreshLocalhostPorts()
            }
            timer.tolerance = 0.4
            localhostRefreshTimer = timer
        }
        refreshLocalhostPorts()
    }

    private func updateNetworkMonitoring() {
        guard selectedInspectorTab == .network else {
            networkActivityTimer?.invalidate()
            networkActivityTimer = nil
            return
        }
        if networkActivityTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refreshNetworkActivity()
            }
            timer.tolerance = 0.1
            networkActivityTimer = timer
        }
        refreshNetworkActivity()
    }

    private func refreshNetworkActivity() {
        guard selectedInspectorTab == .network else { return }
        renderNetworkTransportState()
        guard !networkActivityRefreshInFlight else { return }
        networkActivityRefreshInFlight = true
        // A full snapshot and hundreds of AppKit rows are expensive. Poll a
        // tiny page-lifecycle signature and rebuild only after it changes.
        canvas.preview.captureNetworkActivitySignature { [weak self] result in
            guard let self else { return }
            guard self.selectedInspectorTab == .network else {
                self.networkActivityRefreshInFlight = false
                return
            }
            switch result {
            case .failure(let error):
                self.networkActivityRefreshInFlight = false
                self.networkActivitySummary?.stringValue = "Could not read resource activity: \(error.localizedDescription)"
                self.networkActivitySummary?.textColor = DeckTheme.danger
            case .success(let signature):
                guard signature != self.networkActivitySignature else {
                    self.networkActivityRefreshInFlight = false
                    self.renderNetworkActivitySummary(self.networkActivitySnapshot)
                    return
                }
                self.captureNetworkActivity(for: signature)
            }
        }
    }

    private func captureNetworkActivity(for signature: String) {
        canvas.preview.captureNetworkActivity { [weak self] result in
            guard let self else { return }
            self.networkActivityRefreshInFlight = false
            guard self.selectedInspectorTab == .network else { return }
            switch result {
            case .failure(let error):
                self.networkActivitySummary?.stringValue = "Could not read resource activity: \(error.localizedDescription)"
                self.networkActivitySummary?.textColor = DeckTheme.danger
            case .success(let snapshot):
                self.networkActivitySignature = signature
                guard snapshot != self.networkActivitySnapshot else {
                    self.renderNetworkActivitySummary(snapshot)
                    return
                }
                self.networkActivitySnapshot = snapshot
                self.renderNetworkActivity(snapshot)
            }
        }
    }

    private func renderNetworkTransportState() {
        let report = canvas.preview.networkShapingReport()
        let activeConnections = report["activeConnectionCount"] as? Int ?? 0
        let acceptedConnections = report["acceptedConnectionCount"] as? Int ?? 0
        let status = canvas.preview.networkShapingStatus
        let connections = "\(activeConnections) active · \(acceptedConnections) total"
        if networkStatusValue?.stringValue != status {
            networkStatusValue?.stringValue = status
        }
        if networkConnectionsValue?.stringValue != connections {
            networkConnectionsValue?.stringValue = connections
        }
        networkReloadButton?.isEnabled = canvas.preview.currentURL != nil
        let statusColor = report["trafficObserved"] as? Bool == true
            ? DeckTheme.accentBright
            : DeckTheme.secondaryText
        if networkStatusValue?.textColor != statusColor {
            networkStatusValue?.textColor = statusColor
        }
    }

    private func renderNetworkActivity(_ snapshot: NetworkActivitySnapshot) {
        renderNetworkTransportState()
        renderNetworkActivitySummary(snapshot)

        guard let stack = networkResourceStack else { return }
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !snapshot.resources.isEmpty else {
            let empty = helpText("Reload the page to capture its document, scripts, styles, images, fonts, fetch/XHR, and media requests.")
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return
        }
        for resource in snapshot.resources {
            let view = networkResourceView(resource)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func renderNetworkActivitySummary(_ snapshot: NetworkActivitySnapshot) {
        let total = snapshot.resources.count
        networkActivitySummary?.stringValue = total == 0
            ? "No page resources observed yet."
            : "\(snapshot.completedCount) complete · \(snapshot.pendingCount) pending · \(snapshot.failedCount) failed"
        networkActivitySummary?.textColor = snapshot.failedCount > 0 ? DeckTheme.danger : DeckTheme.muted

        if let progress = networkActivityProgress {
            let needsIndeterminateProgress = snapshot.loading && total == 0
            progress.isIndeterminate = needsIndeterminateProgress
            progress.doubleValue = snapshot.progress
            if needsIndeterminateProgress { progress.startAnimation(nil) }
            else { progress.stopAnimation(nil) }
            progress.setAccessibilityValue("\(Int(snapshot.progress * 100)) percent")
        }
    }

    private func networkResourceView(_ resource: NetworkResourceActivity) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.distribution = .fill
        heading.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: networkResourceName(resource.url))
        name.font = .systemFont(ofSize: 10.5, weight: .semibold)
        name.textColor = DeckTheme.text
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = resource.url
        let status = NSTextField(labelWithString: resource.status.rawValue.uppercased())
        status.font = .monospacedSystemFont(ofSize: 8.5, weight: .bold)
        status.textColor = networkResourceColor(resource.status)
        status.setContentHuggingPriority(.required, for: .horizontal)
        heading.addArrangedSubview(name)
        heading.addArrangedSubview(status)
        stack.addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let details = [
            resource.initiatorType,
            resource.responseStatus.map { "HTTP \($0)" },
            resource.transferSizeBytes.map(Self.networkByteCount),
            resource.durationMilliseconds.map { "\(Int($0.rounded())) ms" },
            resource.fromCache ? "cache" : nil,
            resource.error
        ].compactMap { $0 }.joined(separator: " · ")
        let detail = helpText(details)
        detail.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = details
        stack.addArrangedSubview(detail)
        detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = resource.status == .pending
        progress.doubleValue = resource.status == .pending ? 0 : 1
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 4).isActive = true
        progress.setAccessibilityLabel("\(networkResourceName(resource.url)) load status")
        progress.setAccessibilityValue(resource.status.rawValue)
        if resource.status == .pending { progress.startAnimation(nil) }
        stack.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func networkResourceName(_ rawURL: String) -> String {
        guard let url = URL(string: rawURL) else { return rawURL }
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return name.isEmpty ? (url.host ?? rawURL) : name
    }

    private func networkResourceColor(_ status: NetworkResourceStatus) -> NSColor {
        switch status {
        case .pending: DeckTheme.accentBright
        case .complete: DeckTheme.secondaryText
        case .failed: DeckTheme.danger
        }
    }

    private static func networkByteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    @objc private func refreshLocalhostPorts() {
        guard !localhostScanInProgress else { return }
        localhostScanInProgress = true
        localhostScanError = nil
        if selectedInspectorTab == .ports { rebuildInspector() }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try LocalhostPortScanner.scan() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.localhostScanInProgress = false
                switch result {
                case .success(let processes):
                    self.localhostProcesses = processes
                    self.localhostScanError = nil
                case .failure(let error):
                    self.localhostScanError = error.localizedDescription
                }
                if self.selectedInspectorTab == .ports { self.rebuildInspector() }
            }
        }
    }

    @objc private func openLocalhostPort(_ sender: NSButton) {
        guard sender.tag > 0 else { return }
        let address = "http://localhost:\(sender.tag)/"
        addressField.stringValue = address
        toolbarModel.address = address
        UserDefaults.standard.set(address, forKey: "viewdeck.native.last-url")
        canvas.preview.loadLocalServer(address, resetSiteData: false)
    }

    @objc private func stopLocalhostProcess(_ sender: NSButton) {
        let pid = pid_t(sender.tag)
        guard let process = localhostProcesses.first(where: { $0.pid == pid }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop \(process.displayName)?"
        alert.informativeText = "This will send a termination signal to PID \(pid), listening on \(process.ports.map(String.init).joined(separator: ", "))."
        alert.addButton(withTitle: "Stop process")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if server.ownsProcess(pid) {
            stopLocalProcessAndClearPreview()
        } else {
            _ = kill(pid, SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshLocalhostPorts()
        }
    }

    private func refreshDeviceLists() {
        deviceListStack.arrangedSubviews.forEach { deviceListStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, device) in devices.enumerated() {
            let button = makeSidebarButton(
                device.name,
                symbol: sidebarSymbol(for: device, at: index),
                action: #selector(sidebarDeviceSelected)
            )
            let isCustom = index >= BuiltinDevices.all.count
            button.tag = index
            button.toolTip = isCustom
                ? "Apply \(device.name). Right-click to edit or remove it."
                : "Preview with \(device.name). Right-click to customize it."
            button.menu = deviceContextMenu(at: index)
            button.state = index == selectedIndex ? .on : .off
            applySidebarSelection(button, selected: index == selectedIndex)
            deviceListStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: deviceListStack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
    }

    private func sidebarSymbol(for device: DeviceProfile, at index: Int) -> String {
        if index >= BuiltinDevices.all.count {
            return customSetups[index - BuiltinDevices.all.count].landscape ? "rectangle" : "iphone"
        }
        switch device.platform {
        case .desktop: return "display"
        case .tablet: return "ipad"
        default: return "iphone"
        }
    }

    private func deviceContextMenu(at index: Int) -> NSMenu {
        let menu = NSMenu()
        let isCustom = index >= BuiltinDevices.all.count
        let edit = NSMenuItem(
            title: isCustom ? "Edit Device…" : "Customize Device…",
            action: #selector(editSidebarDevice(_:)),
            keyEquivalent: ""
        )
        edit.target = self
        edit.tag = index
        menu.addItem(edit)

        if isCustom {
            menu.addItem(.separator())
            let remove = NSMenuItem(
                title: "Remove Device",
                action: #selector(removeSidebarDevice(_:)),
                keyEquivalent: ""
            )
            remove.target = self
            remove.tag = index
            menu.addItem(remove)
        }
        return menu
    }

    private func selectDevice(at index: Int) {
        guard devices.indices.contains(index) else { return }
        selectedIndex = index
        let device = devices[index]
        canvas.preview.profile = device
        widthField.doubleValue = device.viewport.width
        heightField.doubleValue = device.viewport.height
        toolbarModel.width = Int(device.viewport.width).description
        toolbarModel.height = Int(device.viewport.height).description
        toolbarModel.dpr = device.viewport.dpr
        preferences.selectedDeviceID = device.id
        if index >= BuiltinDevices.all.count {
            applyCustomSetup(customSetups[index - BuiltinDevices.all.count])
        }
        refreshDeviceLists()
        updateStatus()
        rebuildInspector()
    }

    private func applyCustomSetup(_ setup: CustomDeviceSetup) {
        canvas.preview.landscape = setup.landscape
        preferences.isLandscape = setup.landscape
        for kind in HTMLLayerKind.allCases {
            applyCustomLayer(setup.layer(kind), kind: kind)
        }
    }

    private func applyCustomLayer(
        _ selection: CustomDeviceLayerSelection,
        kind: HTMLLayerKind
    ) {
        let builtIn = Self.builtInLayer(for: kind)
        let libraryLayer = layerLibrary.first {
            $0.kind == kind && $0.id == selection.identifier
        }
        let isBuiltIn = selection.identifier == builtIn?.id
        let html = isBuiltIn
            ? builtIn?.html
            : libraryLayer.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) }
        let path = libraryLayer?.url
        let baseURL = path?.deletingLastPathComponent()
        let activeIdentifier = html == nil ? nil : selection.identifier

        if let activeIdentifier {
            UserDefaults.standard.set(activeIdentifier, forKey: activeLayerDefaultsKey(kind))
        } else {
            UserDefaults.standard.removeObject(forKey: activeLayerDefaultsKey(kind))
        }

        switch kind {
        case .header:
            sampleHeaderEnabled = isBuiltIn && html != nil
            headerPath = path
            canvas.preview.headerBaseURL = baseURL
            canvas.preview.headerHeight = selection.extent
            canvas.preview.headerHTML = html
        case .footer:
            footerPath = path
            canvas.preview.footerBaseURL = baseURL
            canvas.preview.footerHeight = selection.extent
            canvas.preview.footerHTML = html
        case .left:
            sampleLeftEnabled = isBuiltIn && html != nil
            leftPath = path
            canvas.preview.leftBaseURL = baseURL
            canvas.preview.leftWidth = selection.extent
            canvas.preview.leftHTML = html
        case .right:
            sampleRightEnabled = isBuiltIn && html != nil
            rightPath = path
            canvas.preview.rightBaseURL = baseURL
            canvas.preview.rightWidth = selection.extent
            canvas.preview.rightHTML = html
        }
    }

    private func updateStatus() {
        let logical = canvas.preview.logicalViewportSize
        toolbarModel.width = Int(logical.width).description
        toolbarModel.height = Int(logical.height).description
        toolbarModel.dpr = canvas.preview.profile.viewport.dpr
        canvas.needsLayout = true
    }

    @objc private func sidebarDeviceSelected(_ sender: NSButton) { selectDevice(at: sender.tag) }

    @objc private func viewportChanged() {
        var device = canvas.preview.profile
        device.viewport.width = max(240, widthField.doubleValue)
        device.viewport.height = max(320, heightField.doubleValue)
        canvas.preview.profile = device
        updateStatus(); rebuildInspector()
    }

    @objc private func inspectorNameChanged(_ sender: NSTextField) {
        let name = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            rebuildInspector()
            return
        }
        updatePreviewProfile { $0.name = name }
    }

    @objc private func inspectorPlatformChanged(_ sender: NSPopUpButton) {
        guard let value = sender.titleOfSelectedItem,
              let platform = DevicePlatform(rawValue: value) else { return }
        updatePreviewProfile { $0.platform = platform }
    }

    @objc private func inspectorOrientationChanged(_ sender: NSSegmentedControl) {
        let landscape = sender.selectedSegment == 1
        guard canvas.preview.landscape != landscape else { return }
        canvas.preview.landscape = landscape
        preferences.isLandscape = landscape
        updateStatus()
        rebuildInspector()
    }

    @objc private func inspectorWidthChanged(_ sender: NSTextField) {
        var device = canvas.preview.profile
        if canvas.preview.landscape { device.viewport.height = max(240, sender.doubleValue) }
        else { device.viewport.width = max(240, sender.doubleValue) }
        canvas.preview.profile = device
        widthField.doubleValue = device.viewport.width
        updateStatus(); rebuildInspector()
    }

    @objc private func inspectorHeightChanged(_ sender: NSTextField) {
        var device = canvas.preview.profile
        if canvas.preview.landscape { device.viewport.width = max(320, sender.doubleValue) }
        else { device.viewport.height = max(320, sender.doubleValue) }
        canvas.preview.profile = device
        heightField.doubleValue = device.viewport.height
        updateStatus(); rebuildInspector()
    }

    @objc private func inspectorDPRChanged(_ sender: NSTextField) {
        setDPR(sender.doubleValue)
    }

    @objc private func inspectorShellChanged(_ sender: NSTextField) {
        guard let metric = ShellMetric(rawValue: sender.tag) else { return }
        let value = max(0, CGFloat(sender.doubleValue))
        updatePreviewProfile { profile in
            switch metric {
            case .top: profile.shell.top = value
            case .right: profile.shell.right = value
            case .bottom: profile.shell.bottom = value
            case .left: profile.shell.left = value
            case .radius: profile.shell.radius = value
            }
        }
    }

    @objc private func inspectorSensorTypeChanged(_ sender: NSPopUpButton) {
        guard let value = sender.titleOfSelectedItem,
              let sensor = SensorType(rawValue: value) else { return }
        updatePreviewProfile { $0.sensor.type = sensor }
    }

    @objc private func inspectorSensorChanged(_ sender: NSTextField) {
        guard let metric = SensorMetric(rawValue: sender.tag) else { return }
        let value = max(0, CGFloat(sender.doubleValue))
        updatePreviewProfile { profile in
            switch metric {
            case .width: profile.sensor.width = value
            case .height: profile.sensor.height = value
            case .top: profile.sensor.top = value
            }
        }
    }

    @objc private func inspectorHomeIndicatorChanged(_ sender: NSButton) {
        updatePreviewProfile { $0.homeIndicator = sender.state == .on }
    }

    private func updatePreviewProfile(_ update: (inout DeviceProfile) -> Void) {
        var profile = canvas.preview.profile
        update(&profile)
        canvas.preview.profile = profile
        updateStatus()
        rebuildInspector()
    }

    private func setDPR(_ value: Double) {
        var device = canvas.preview.profile
        device.viewport.dpr = max(0.5, min(8, value))
        canvas.preview.profile = device
        updateStatus(); rebuildInspector()
    }

    @objc private func rotateDevice() {
        canvas.preview.landscape.toggle()
        preferences.isLandscape = canvas.preview.landscape
        updateStatus(); rebuildInspector()
    }

    @objc private func toggleSafari(_ sender: Any?) {
        var device = canvas.preview.profile
        if let button = sender as? NSButton, button.title == "iOS Safari interface" { device.safariChrome = button.state == .on }
        else { device.safariChrome.toggle() }
        canvas.preview.profile = device
        updateStatus(); rebuildInspector()
    }

    @objc private func loadPreview() {
        let value = addressField.stringValue
        canvas.preview.load(value)
    }

    @objc private func reloadPreview() { canvas.preview.reload() }
    @objc private func reloadPreviewFromOrigin() {
        window?.makeFirstResponder(nil)
        canvas.preview.reloadFromOrigin()
    }
    @objc private func goBack() { canvas.preview.goBack() }
    @objc private func goForward() { canvas.preview.goForward() }

    private func captureScreenshot() {
        guard !toolbarModel.isCapturingScreenshot else { return }
        toolbarModel.isCapturingScreenshot = true
        canvas.preview.captureVideoFrame(scale: canvas.preview.profile.viewport.dpr) { [weak self] result in
            guard let self else { return }
            self.toolbarModel.isCapturingScreenshot = false
            switch result {
            case .success(let image):
                let editor = ScreenshotEditorWindowController(
                    image: image,
                    suggestedName: self.canvas.preview.profile.name
                )
                editor.onClose = { [weak self] closedEditor in
                    self?.screenshotEditors.removeAll { $0 === closedEditor }
                }
                self.screenshotEditors.append(editor)
                editor.showWindow(nil)
                editor.window?.makeKeyAndOrderFront(nil)
            case .failure(let error):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t capture the device"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                if let window = self.window {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
    }

    private func toggleVideoRecording() {
        if let recorder = standaloneVideoRecorder {
            guard toolbarModel.videoCaptureState == .recording else { return }
            toolbarModel.videoCaptureState = .saving
            recorder.stop()
            return
        }

        guard canvas.preview.currentURL != nil else {
            NSSound.beep()
            presentInformation(
                title: "Load a page first",
                message: "ViewDeck needs a loaded page before it can record a video."
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = "Record device video"
        panel.nameFieldStringValue = "viewdeck-capture.mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let recorder = LivePreviewVideoRecorder(
            outputURL: outputURL,
            duration: nil,
            framesPerSecond: 30,
            captureScale: 1,
            overwrite: true
        )
        standaloneVideoRecorder = recorder
        toolbarModel.videoCaptureState = .recording
        recorder.record(preview: canvas.preview) { [weak self, weak recorder] result in
            guard let self, let recorder, self.standaloneVideoRecorder === recorder else { return }
            self.standaloneVideoRecorder = nil
            self.toolbarModel.videoCaptureState = .idle
            switch result {
            case .success:
                self.presentInformation(
                    title: "Video saved",
                    message: "The device recording was saved as \(outputURL.lastPathComponent)."
                )
            case .failure(let error):
                self.presentError(title: "Couldn’t save the video", error: error)
            }
        }
    }

    private func toggleQARecording() {
        guard standaloneVideoRecorder == nil else { return }
        if pendingQARecording != nil {
            pendingQARecording = nil
            toolbarModel.isQARecording = false
            toolbarModel.isQARecordingReady = false
            return
        }
        if let recorder = qaRecorder {
            toolbarModel.isQARecording = false
            toolbarModel.isQARecordingReady = false
            recorder.stop { [weak self] result in
                guard let self else { return }
                self.qaRecorder = nil
                switch result {
                case .success(let scenario):
                    self.presentInformation(
                        title: "Test scenario saved",
                        message: "\(scenario.events.count) input events, \(scenario.checkpoints.count) checkpoints, and the replay configuration were saved."
                    )
                case .failure(let error):
                    self.presentError(title: "Couldn’t save the test scenario", error: error)
                }
            }
            return
        }

        guard let targetURL = canvas.preview.currentURL else {
            NSSound.beep()
            presentInformation(
                title: "Load a page first",
                message: "ViewDeck needs a loaded page before it can record a QA scenario."
            )
            return
        }
        let panel = NSSavePanel()
        panel.title = "Record test scenario"
        panel.nameFieldStringValue = "gameplay.viewdeck.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let includeVideo = NSButton(
            checkboxWithTitle: "Include an MP4 with this test recording",
            target: nil,
            action: nil
        )
        includeVideo.state = .off
        includeVideo.sizeToFit()
        panel.accessoryView = includeVideo
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let source = currentQASourceConfiguration()
        let header = currentQALayerConfiguration(kind: .header)
        let footer = currentQALayerConfiguration(kind: .footer)
        let left = currentQALayerConfiguration(kind: .left)
        let right = currentQALayerConfiguration(kind: .right)
        let configuration = QADeviceConfiguration.capture(
            preview: canvas.preview,
            header: header,
            footer: footer,
            left: left,
            right: right
        )
        let recorder = QAScenarioRecorder(
            preview: canvas.preview,
            outputURL: outputURL,
            source: source,
            configuration: configuration
        )
        pendingQARecording = QARecordingRequest(
            recorder: recorder,
            targetURL: targetURL,
            captureVideo: includeVideo.state == .on
        )
        toolbarModel.qaCheckpointCount = 0
        toolbarModel.isQARecording = true
        toolbarModel.isQARecordingReady = false
        canvas.preview.reloadResettingSiteData()
    }

    private func addQACheckpoint() {
        guard let recorder = qaRecorder else { return }
        recorder.addCheckpoint { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.toolbarModel.qaCheckpointCount += 1
            case .failure(let error):
                self.presentError(title: "Couldn’t capture the checkpoint", error: error)
            }
        }
    }

    private func chooseAndReplayQAScenario() {
        let panel = NSOpenPanel()
        panel.title = "Replay QA scenario"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let scenarioURL = panel.url else { return }

        do {
            let scenario = try QAScenarioFiles.load(scenarioURL)
            guard scenario.schemaVersion == 1 else {
                throw QAAppError.unsupportedSchema(scenario.schemaVersion)
            }
            presentReplayOptions(scenario: scenario, scenarioURL: scenarioURL)
        } catch {
            presentError(title: "Couldn’t open the QA scenario", error: error)
        }
    }

    private func presentReplayOptions(scenario: QAScenario, scenarioURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Replay “\(scenario.name)”?"
        alert.informativeText = "\(scenario.events.count) input events will run using the exact recorded device and layout configuration."
        alert.addButton(withTitle: "Replay")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 10
        let speedLabel = NSTextField(labelWithString: "Playback speed")
        speedLabel.font = .systemFont(ofSize: 11, weight: .medium)
        let speedPopup = NSPopUpButton()
        speedPopup.addItems(withTitles: ["0.5×", "1×", "2×", "4×", "Maximum"])
        speedPopup.selectItem(withTitle: "1×")
        let capture = NSButton(checkboxWithTitle: "Capture replay video and checkpoint screenshots", target: nil, action: nil)
        capture.state = .on
        accessory.addArrangedSubview(speedLabel)
        accessory.addArrangedSubview(speedPopup)
        accessory.addArrangedSubview(capture)
        accessory.frame = CGRect(x: 0, y: 0, width: 350, height: 82)
        alert.accessoryView = accessory
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let speeds = [0.5, 1, 2, 4, 0]
        let speed = speeds[max(0, speedPopup.indexOfSelectedItem)]
        let request = QAReplayRequest(
            scenario: scenario,
            scenarioURL: scenarioURL,
            speed: speed,
            captureArtifacts: capture.state == .on,
            started: false
        )
        applyRecordedConfiguration(scenario.configuration)
        pendingQAReplay = request
        toolbarModel.isQAReplaying = true
        loadRecordedSource(scenario.source)
    }

    private func currentQASourceConfiguration() -> QASourceConfiguration {
        let launchModeName: String?
        switch launchMode {
        case .npmScript: launchModeName = projectFolder == nil ? "url" : "npmScript"
        case .staticHTML: launchModeName = "staticHTML"
        case .customCommand: launchModeName = "customCommand"
        }
        return QASourceConfiguration(
            requestedURL: addressField.stringValue,
            finalURL: canvas.preview.currentURL?.absoluteString,
            pageTitle: nil,
            projectPath: projectFolder?.path,
            launchMode: launchModeName,
            npmScript: launchMode == .npmScript ? scriptPopup.titleOfSelectedItem : nil,
            customCommand: launchMode == .customCommand ? customCommandField.stringValue : nil,
            staticHTMLPath: launchMode == .staticHTML ? staticHTMLFile?.path : nil
        )
    }

    private func currentQALayerConfiguration(kind: HTMLLayerKind) -> QALayerConfiguration {
        let html: String?
        let path: URL?
        let baseURL: URL?
        let extent: CGFloat
        let builtInEnabled: Bool
        switch kind {
        case .header:
            html = canvas.preview.headerHTML
            path = headerPath
            baseURL = canvas.preview.headerBaseURL
            extent = canvas.preview.headerHeight
            builtInEnabled = sampleHeaderEnabled
        case .footer:
            html = canvas.preview.footerHTML
            path = footerPath
            baseURL = canvas.preview.footerBaseURL
            extent = canvas.preview.footerHeight
            builtInEnabled = false
        case .left:
            html = canvas.preview.leftHTML
            path = leftPath
            baseURL = canvas.preview.leftBaseURL
            extent = canvas.preview.leftWidth
            builtInEnabled = sampleLeftEnabled
        case .right:
            html = canvas.preview.rightHTML
            path = rightPath
            baseURL = canvas.preview.rightBaseURL
            extent = canvas.preview.rightWidth
            builtInEnabled = sampleRightEnabled
        }
        let reference = path.flatMap { path in
            layerLibrary.first { $0.kind == kind && $0.path == path.path }
        }
        let builtIn = builtInEnabled ? Self.builtInLayer(for: kind) : nil
        return QALayerConfiguration(
            kind: kind,
            html: html,
            height: extent,
            sourcePath: path?.path,
            baseURL: baseURL,
            identifier: builtIn?.id ?? reference?.id,
            name: builtIn?.name ?? reference?.name
        )
    }

    private func applyRecordedConfiguration(_ configuration: QADeviceConfiguration) {
        canvas.preview.profile = configuration.profile
        canvas.preview.safeArea = configuration.safeArea.configuredPortrait
        canvas.preview.landscape = configuration.orientation == "landscape"
        preferences.isLandscape = canvas.preview.landscape
        canvas.preview.showSafeArea = configuration.safeArea.guideVisible
        canvas.preview.applySafeAreaToPage = configuration.safeArea.forcedIntoPageLayout
        applyNetworkShapingConfiguration(
            configuration.network ?? .disabled,
            reloadIfNeeded: false
        )

        let header = configuration.header
        sampleHeaderEnabled = header.identifier == "builtin-sample-header"
        headerPath = header.sourcePath.map(URL.init(fileURLWithPath:))
        canvas.preview.headerBaseURL = header.baseURL.flatMap(URL.init(string:))
            ?? headerPath?.deletingLastPathComponent()
        canvas.preview.headerHeight = CGFloat(header.heightCSSPixels)
        canvas.preview.headerHTML = header.enabled ? header.html : nil

        let footer = configuration.footer
        footerPath = footer.sourcePath.map(URL.init(fileURLWithPath:))
        canvas.preview.footerBaseURL = footer.baseURL.flatMap(URL.init(string:))
            ?? footerPath?.deletingLastPathComponent()
        canvas.preview.footerHeight = CGFloat(footer.heightCSSPixels)
        canvas.preview.footerHTML = footer.enabled ? footer.html : nil

        applyRecordedSideLayer(configuration.left, kind: .left)
        applyRecordedSideLayer(configuration.right, kind: .right)
        updateStatus()
        rebuildInspector()
    }

    private func applyRecordedSideLayer(_ layer: QALayerConfiguration?, kind: HTMLLayerKind) {
        guard kind.isSide else { return }
        let builtIn = layer.flatMap { configuration in
            Self.builtInLayer(for: kind).flatMap { $0.id == configuration.identifier ? $0 : nil }
        }
        let path = layer?.sourcePath.map(URL.init(fileURLWithPath:))
        let baseURL = layer?.baseURL.flatMap(URL.init(string:))
            ?? path?.deletingLastPathComponent()
        let html = layer?.enabled == true ? layer?.html : nil
        let extent = CGFloat(layer?.reservedExtentCSSPixels ?? Double(kind.defaultExtent))
        if kind == .left {
            sampleLeftEnabled = builtIn != nil
            leftPath = path
            canvas.preview.leftBaseURL = baseURL
            canvas.preview.leftWidth = extent
            canvas.preview.leftHTML = html
        } else {
            sampleRightEnabled = builtIn != nil
            rightPath = path
            canvas.preview.rightBaseURL = baseURL
            canvas.preview.rightWidth = extent
            canvas.preview.rightHTML = html
        }
    }

    private func loadRecordedSource(_ source: QASourceConfiguration) {
        if source.launchMode == "staticHTML",
           let path = source.staticHTMLPath,
           FileManager.default.fileExists(atPath: path) {
            let file = URL(fileURLWithPath: path)
            staticHTMLFile = file
            canvas.preview.loadLocalFile(file, resetSiteData: true)
            return
        }

        let recordedProjectPath = source.projectPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        }
        if let finalURL = source.finalURL,
           server.state == .running,
           let recordedProjectPath,
           projectFolder?.standardizedFileURL.path == recordedProjectPath {
            canvas.preview.loadLocalServer(finalURL, resetSiteData: true)
            return
        }

        if source.projectPath != nil {
            if server.state == .running || server.state == .starting || server.state == .stopping {
                pendingQAServerLaunch = source
                server.stop()
            } else {
                startRecordedProject(source)
            }
            return
        }

        guard let value = source.finalURL ?? source.requestedURL else {
            pendingQAReplay = nil
            presentError(title: "Couldn’t replay the scenario", error: QAAppError.missingSource)
            return
        }
        addressField.stringValue = value
        toolbarModel.address = value
        canvas.preview.loadResettingSiteData(value)
    }

    private func startRecordedProject(_ source: QASourceConfiguration) {
        guard let path = source.projectPath else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        projectFolder = folder
        do {
            canvas.preview.prepareForLocalServerLaunch()
            if source.launchMode == "customCommand", let command = source.customCommand {
                try server.startCommand(folder: folder, command: command)
            } else {
                try server.start(folder: folder, script: source.npmScript ?? "dev")
            }
        } catch {
            pendingQAReplay = nil
            pendingQAServerLaunch = nil
            toolbarModel.isQAReplaying = false
            presentError(title: "Couldn’t start the recorded project", error: error)
        }
    }

    private func replaySourceMatches(_ url: URL, source: QASourceConfiguration) -> Bool {
        if source.launchMode == "staticHTML", let path = source.staticHTMLPath {
            return url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
        }
        guard let raw = source.finalURL ?? source.requestedURL,
              let expected = URL(string: raw) else { return true }
        if source.projectPath != nil {
            return url.path == expected.path && url.query == expected.query
        }
        return url.absoluteString == expected.absoluteString
    }

    private func replayURL(serverURL: URL, source: QASourceConfiguration) -> URL {
        guard let raw = source.finalURL,
              let recorded = URL(string: raw),
              var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
        components.path = recorded.path
        components.query = recorded.query
        components.fragment = recorded.fragment
        return components.url ?? serverURL
    }

    private func beginPendingQAReplayIfNeeded() {
        guard var request = pendingQAReplay, !request.started else { return }
        request.started = true
        pendingQAReplay = request
        toolbarModel.isQAReplaying = true
        replayStartedAt = Date()
        replaySummary = nil
        replayArtifacts = []
        replayErrors = []
        replayVideoFinished = !request.captureArtifacts

        if request.captureArtifacts {
            let videoURL = replayArtifactURL(
                scenarioURL: request.scenarioURL,
                suffix: "replay",
                extension: "mp4"
            )
            let recorder = LivePreviewVideoRecorder(
                outputURL: videoURL,
                duration: nil,
                framesPerSecond: 30,
                captureScale: 1,
                overwrite: true
            )
            replayVideoRecorder = recorder
            recorder.record(preview: canvas.preview) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.replayArtifacts.append([
                        "kind": "replayVideo",
                        "path": videoURL.path,
                        "mediaType": "video/mp4"
                    ])
                case .failure(let error):
                    self.replayErrors.append(error.localizedDescription)
                }
                self.replayVideoFinished = true
                self.finishQAReplayIfReady()
            }
        }

        let playback = QAPlaybackController(
            preview: canvas.preview,
            scenario: request.scenario,
            speed: request.speed,
            checkpointHandler: { [weak self] checkpoint, done in
                guard let self, request.captureArtifacts else {
                    done()
                    return
                }
                let screenshotURL = self.replayArtifactURL(
                    scenarioURL: request.scenarioURL,
                    suffix: "replay-\(checkpoint.id.prefix(8))",
                    extension: "png"
                )
                self.canvas.preview.captureVideoFrame(
                    scale: self.canvas.preview.profile.viewport.dpr
                ) { result in
                    do {
                        let image = try result.get()
                        try PreviewImageEncoding.pngData(image).write(to: screenshotURL, options: .atomic)
                        self.replayArtifacts.append([
                            "kind": "checkpointScreenshot",
                            "checkpointID": checkpoint.id,
                            "checkpointName": checkpoint.name,
                            "path": screenshotURL.path,
                            "mediaType": "image/png"
                        ])
                    } catch {
                        self.replayErrors.append(error.localizedDescription)
                    }
                    done()
                }
            },
            completion: { [weak self] summary in
                guard let self else { return }
                self.replaySummary = summary
                self.replayErrors.append(contentsOf: summary.errorMessages)
                self.replayVideoRecorder?.stop()
                self.finishQAReplayIfReady()
            }
        )
        qaPlayback = playback
        playback.start()
    }

    private func stopQAReplay() {
        guard toolbarModel.isQAReplaying else { return }
        if let qaPlayback {
            qaPlayback.cancel()
            return
        }
        pendingQAReplay = nil
        pendingQAServerLaunch = nil
        replayVideoRecorder?.stop()
        replayVideoRecorder = nil
        replaySummary = nil
        replayArtifacts = []
        replayErrors = []
        toolbarModel.isQAReplaying = false
    }

    private func finishQAReplayIfReady() {
        guard replaySummary != nil, replayVideoFinished, let request = pendingQAReplay else { return }
        let reportURL = replayArtifactURL(
            scenarioURL: request.scenarioURL,
            suffix: "replay-report",
            extension: "json"
        )
        let summary = replaySummary!
        let wasCancelled = summary.wasCancelled
        let report: [String: Any] = [
            "schemaVersion": 1,
            "ok": replayErrors.isEmpty && !wasCancelled,
            "cancelled": wasCancelled,
            "scenario": [
                "id": request.scenario.id,
                "name": request.scenario.name,
                "path": request.scenarioURL.path
            ],
            "playback": [
                "speed": request.speed == 0 ? "maximum" : request.speed,
                "eventCount": summary.eventCount,
                "checkpointCount": summary.checkpointCount,
                "elapsedMilliseconds": summary.elapsedMilliseconds,
                "startedAt": ISO8601DateFormatter().string(from: replayStartedAt ?? Date()),
                "finishedAt": ISO8601DateFormatter().string(from: Date())
            ],
            "errors": replayErrors,
            "artifacts": replayArtifacts
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: report,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: reportURL, options: .atomic)
            replayArtifacts.append([
                "kind": "replayReport",
                "path": reportURL.path,
                "mediaType": "application/json"
            ])
            presentInformation(
                title: wasCancelled
                    ? "QA replay stopped"
                    : (replayErrors.isEmpty ? "QA replay finished" : "QA replay finished with warnings"),
                message: "\(summary.eventCount) events replayed\(wasCancelled ? " before stopping" : ""). Report: \(reportURL.path)"
            )
        } catch {
            presentError(title: "Couldn’t save the replay report", error: error)
        }
        toolbarModel.isQAReplaying = false
        qaPlayback = nil
        pendingQAReplay = nil
        replayVideoRecorder = nil
        replaySummary = nil
    }

    private func replayArtifactURL(scenarioURL: URL, suffix: String, extension pathExtension: String) -> URL {
        let base = scenarioURL.deletingPathExtension().lastPathComponent
        return scenarioURL.deletingLastPathComponent()
            .appendingPathComponent("\(base).\(suffix)")
            .appendingPathExtension(pathExtension)
    }

    private func presentInformation(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func inspectorTabChanged() {
        preferences.inspectorTabIndex = inspectorTabs.selectedSegment
        rebuildInspector()
        updateLocalhostMonitoring()
        updateNetworkMonitoring()
    }

    @objc private func safeAreaChanged(_ sender: NSTextField) {
        var safe = canvas.preview.safeArea
        switch sender.tag {
        case 0: safe.top = max(0, sender.doubleValue)
        case 1: safe.right = max(0, sender.doubleValue)
        case 2: safe.bottom = max(0, sender.doubleValue)
        case 3: safe.left = max(0, sender.doubleValue)
        default: break
        }
        canvas.preview.safeArea = safe
        updateStatus()
    }

    @objc private func showSafeAreaChanged(_ sender: NSButton) { canvas.preview.showSafeArea = sender.state == .on }
    @objc private func applySafeAreaChanged(_ sender: NSButton) { canvas.preview.applySafeAreaToPage = sender.state == .on }

    @objc private func networkShapingEnabledChanged(_ sender: NSButton) {
        var configuration = canvas.preview.networkShapingConfiguration
        configuration.enabled = sender.state == .on
        if !configuration.enabled { configuration.offline = false }
        applyNetworkShapingConfiguration(configuration)
    }

    @objc private func networkShapingOfflineChanged(_ sender: NSButton) {
        var configuration = canvas.preview.networkShapingConfiguration
        configuration.offline = sender.state == .on
        if configuration.offline { configuration.enabled = true }
        applyNetworkShapingConfiguration(configuration)
    }

    @objc private func networkShapingValueChanged(_ sender: NSTextField) {
        var configuration = canvas.preview.networkShapingConfiguration
        let value = max(0, sender.doubleValue)
        let displayedValue: Double
        switch sender.tag {
        case 0:
            configuration.roundTripTimeMilliseconds = value
            displayedValue = value
        case 1:
            configuration.jitterMilliseconds = value
            displayedValue = value
        case 2:
            configuration.downloadKilobitsPerSecond = value
            displayedValue = value
        case 3:
            configuration.uploadKilobitsPerSecond = value
            displayedValue = value
        case 4:
            configuration.seed = UInt64(min(
                value.rounded(),
                Double(NetworkShapingConfiguration.maximumJSONSafeSeed)
            ))
            displayedValue = Double(configuration.seed)
        default: return
        }
        sender.stringValue = CGFloat(displayedValue).formatted()
        applyNetworkShapingConfiguration(configuration, reloadIfNeeded: false)
    }

    private func applyNetworkShapingConfiguration(
        _ configuration: NetworkShapingConfiguration,
        reloadIfNeeded: Bool = true
    ) {
        switch canvas.preview.applyNetworkShapingConfiguration(
            configuration,
            reloadIfNeeded: reloadIfNeeded
        ) {
        case .success:
            preferences.networkShapingConfiguration = configuration
        case .failure(let error):
            presentError(title: "Couldn’t apply network shaping", error: error)
        }
        if reloadIfNeeded { rebuildInspector() }
        else { renderNetworkActivity(networkActivitySnapshot) }
    }

    @objc private func chooseHeader() {
        guard let result = chooseHTMLFile() else { return }
        addLayerToLibrary(url: result.url, kind: .header)
        headerPath = result.url
        sampleHeaderEnabled = false
        canvas.preview.headerBaseURL = result.url.deletingLastPathComponent()
        canvas.preview.headerHTML = result.html
        if let layer = layerLibrary.first(where: { $0.path == result.url.path && $0.kind == .header }) {
            UserDefaults.standard.set(layer.id, forKey: "viewdeck.native.active-header-layer")
        }
        updateStatus(); rebuildInspector()
    }

    @objc private func chooseFooter() {
        guard let result = chooseHTMLFile() else { return }
        addLayerToLibrary(url: result.url, kind: .footer)
        footerPath = result.url
        canvas.preview.footerBaseURL = result.url.deletingLastPathComponent()
        canvas.preview.footerHTML = result.html
        if let layer = layerLibrary.first(where: { $0.path == result.url.path && $0.kind == .footer }) {
            UserDefaults.standard.set(layer.id, forKey: "viewdeck.native.active-footer-layer")
        }
        updateStatus(); rebuildInspector()
    }

    @objc private func chooseLeft() { chooseSideLayer(kind: .left) }
    @objc private func chooseRight() { chooseSideLayer(kind: .right) }

    private func chooseSideLayer(kind: HTMLLayerKind) {
        guard kind.isSide, let result = chooseHTMLFile() else { return }
        addLayerToLibrary(url: result.url, kind: kind)
        let reference = layerLibrary.first { $0.path == result.url.path && $0.kind == kind }
        if kind == .left {
            leftPath = result.url
            sampleLeftEnabled = false
            canvas.preview.leftBaseURL = result.url.deletingLastPathComponent()
            canvas.preview.leftHTML = result.html
        } else {
            rightPath = result.url
            sampleRightEnabled = false
            canvas.preview.rightBaseURL = result.url.deletingLastPathComponent()
            canvas.preview.rightHTML = result.html
        }
        if let reference {
            UserDefaults.standard.set(reference.id, forKey: activeLayerDefaultsKey(kind))
        }
        updateStatus(); rebuildInspector()
    }

    @objc private func editHeaderLayer() { presentLayerEditor(kind: .header) }
    @objc private func editFooterLayer() { presentLayerEditor(kind: .footer) }
    @objc private func editLeftLayer() { presentLayerEditor(kind: .left) }
    @objc private func editRightLayer() { presentLayerEditor(kind: .right) }

    @objc private func headerLayerSelected(_ sender: NSPopUpButton) {
        let identifier = sender.selectedItem?.representedObject as? String
        if identifier == "builtin-sample-header" {
            headerPath = nil
            sampleHeaderEnabled = true
            canvas.preview.headerBaseURL = nil
            canvas.preview.headerHTML = Self.sampleHeaderHTML
            UserDefaults.standard.set("builtin-sample-header", forKey: "viewdeck.native.active-header-layer")
        } else if let layer = layerLibrary.first(where: { $0.id == identifier }) {
            headerPath = layer.url
            sampleHeaderEnabled = false
            canvas.preview.headerBaseURL = layer.url.deletingLastPathComponent()
            canvas.preview.headerHTML = try? String(contentsOf: layer.url, encoding: .utf8)
            UserDefaults.standard.set(layer.id, forKey: "viewdeck.native.active-header-layer")
        } else {
            headerPath = nil
            sampleHeaderEnabled = false
            canvas.preview.headerBaseURL = nil
            canvas.preview.headerHTML = nil
            UserDefaults.standard.removeObject(forKey: "viewdeck.native.active-header-layer")
        }
        updateStatus(); rebuildInspector()
    }

    @objc private func footerLayerSelected(_ sender: NSPopUpButton) {
        let identifier = sender.selectedItem?.representedObject as? String
        if let layer = layerLibrary.first(where: { $0.id == identifier }) {
            footerPath = layer.url
            canvas.preview.footerBaseURL = layer.url.deletingLastPathComponent()
            canvas.preview.footerHTML = try? String(contentsOf: layer.url, encoding: .utf8)
            UserDefaults.standard.set(layer.id, forKey: "viewdeck.native.active-footer-layer")
        } else {
            footerPath = nil
            canvas.preview.footerBaseURL = nil
            canvas.preview.footerHTML = nil
            UserDefaults.standard.removeObject(forKey: "viewdeck.native.active-footer-layer")
        }
        updateStatus(); rebuildInspector()
    }

    @objc private func leftLayerSelected(_ sender: NSPopUpButton) {
        selectSideLayer(sender, kind: .left)
    }

    @objc private func rightLayerSelected(_ sender: NSPopUpButton) {
        selectSideLayer(sender, kind: .right)
    }

    private func selectSideLayer(_ sender: NSPopUpButton, kind: HTMLLayerKind) {
        guard kind.isSide else { return }
        let identifier = sender.selectedItem?.representedObject as? String
        let builtIn = Self.builtInLayer(for: kind)
        let path: URL?
        let html: String?
        let baseURL: URL?
        let isBuiltIn: Bool
        if identifier == builtIn?.id {
            path = nil
            html = builtIn?.html
            baseURL = nil
            isBuiltIn = true
            UserDefaults.standard.set(identifier, forKey: activeLayerDefaultsKey(kind))
        } else if let layer = layerLibrary.first(where: { $0.id == identifier }) {
            path = layer.url
            html = try? String(contentsOf: layer.url, encoding: .utf8)
            baseURL = layer.url.deletingLastPathComponent()
            isBuiltIn = false
            UserDefaults.standard.set(layer.id, forKey: activeLayerDefaultsKey(kind))
        } else {
            path = nil
            html = nil
            baseURL = nil
            isBuiltIn = false
            UserDefaults.standard.removeObject(forKey: activeLayerDefaultsKey(kind))
        }
        if kind == .left {
            leftPath = path
            sampleLeftEnabled = isBuiltIn
            canvas.preview.leftBaseURL = baseURL
            canvas.preview.leftHTML = html
        } else {
            rightPath = path
            sampleRightEnabled = isBuiltIn
            canvas.preview.rightBaseURL = baseURL
            canvas.preview.rightHTML = html
        }
        updateStatus(); rebuildInspector()
    }

    @objc private func headerHeightChanged(_ sender: NSTextField) { canvas.preview.headerHeight = max(20, sender.doubleValue); updateStatus() }
    @objc private func footerHeightChanged(_ sender: NSTextField) { canvas.preview.footerHeight = max(20, sender.doubleValue); updateStatus() }
    @objc private func leftWidthChanged(_ sender: NSTextField) { canvas.preview.leftWidth = max(20, sender.doubleValue); updateStatus() }
    @objc private func rightWidthChanged(_ sender: NSTextField) { canvas.preview.rightWidth = max(20, sender.doubleValue); updateStatus() }
    @objc private func clearLayers() {
        headerPath = nil; footerPath = nil; leftPath = nil; rightPath = nil
        sampleHeaderEnabled = false; sampleLeftEnabled = false; sampleRightEnabled = false
        canvas.preview.headerBaseURL = nil; canvas.preview.footerBaseURL = nil
        canvas.preview.leftBaseURL = nil; canvas.preview.rightBaseURL = nil
        canvas.preview.headerHTML = nil; canvas.preview.footerHTML = nil
        canvas.preview.leftHTML = nil; canvas.preview.rightHTML = nil
        UserDefaults.standard.removeObject(forKey: "viewdeck.native.active-header-layer")
        UserDefaults.standard.removeObject(forKey: "viewdeck.native.active-footer-layer")
        UserDefaults.standard.removeObject(forKey: "viewdeck.native.active-left-layer")
        UserDefaults.standard.removeObject(forKey: "viewdeck.native.active-right-layer")
        updateStatus(); rebuildInspector()
    }

    private func activeLayerDefaultsKey(_ kind: HTMLLayerKind) -> String {
        "viewdeck.native.active-\(kind.rawValue)-layer"
    }

    private func chooseHTMLFile() -> (url: URL, html: String)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (url, html)
    }

    private func addLayerToLibrary(url: URL, kind: HTMLLayerKind) {
        guard !layerLibrary.contains(where: { $0.path == url.path && $0.kind == kind }) else { return }
        layerLibrary.append(HTMLLayerReference(id: UUID().uuidString, name: url.deletingPathExtension().lastPathComponent, path: url.path, kind: kind))
        HTMLLayerStore.save(layerLibrary)
    }

    private func presentLayerEditor(kind: HTMLLayerKind) {
        let activePath: URL?
        let isBuiltIn: Bool
        let liveHTML: String?
        let extent: CGFloat
        switch kind {
        case .header:
            activePath = headerPath
            isBuiltIn = sampleHeaderEnabled
            liveHTML = canvas.preview.headerHTML
            extent = canvas.preview.headerHeight
        case .footer:
            activePath = footerPath
            isBuiltIn = false
            liveHTML = canvas.preview.footerHTML
            extent = canvas.preview.footerHeight
        case .left:
            activePath = leftPath
            isBuiltIn = sampleLeftEnabled
            liveHTML = canvas.preview.leftHTML
            extent = canvas.preview.leftWidth
        case .right:
            activePath = rightPath
            isBuiltIn = sampleRightEnabled
            liveHTML = canvas.preview.rightHTML
            extent = canvas.preview.rightWidth
        }
        let existing = activePath.flatMap { path in
            layerLibrary.first(where: { $0.kind == kind && $0.path == path.path })
        }
        let builtIn = isBuiltIn ? Self.builtInLayer(for: kind) : nil
        let currentHTML: String = {
            if let existing, let html = try? String(contentsOf: existing.url, encoding: .utf8) { return html }
            if let builtIn { return builtIn.html }
            if let liveHTML { return liveHTML }
            return Self.layerTemplate(kind: kind)
        }()
        let initialName = existing?.name ?? builtIn?.name ?? "h5_\(kind.rawValue)"
        let model = LayerEditorModel(name: initialName, html: currentHTML, reservedExtent: extent)

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 650),
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Edit \(kind.rawValue) layer"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = DeckTheme.panel
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.minSize = CGSize(width: 700, height: 580)

        let editor = LayerEditorView(
            model: model,
            kind: kind,
            editingExisting: existing != nil || isBuiltIn,
            onSave: { if model.canSave { NSApp.stopModal(withCode: .OK) } },
            onCancel: { NSApp.stopModal(withCode: .cancel) }
        )
        panel.contentView = NSHostingView(rootView: editor)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        guard response == .OK else { return }

        do {
            let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let destination: URL
            if let existing { destination = existing.url }
            else { destination = try managedLayerURL(name: name, kind: kind) }
            try model.html.write(to: destination, atomically: true, encoding: .utf8)

            let reference = HTMLLayerReference(
                id: existing?.id ?? UUID().uuidString,
                name: name,
                path: destination.path,
                kind: kind
            )
            if let existing, let index = layerLibrary.firstIndex(where: { $0.id == existing.id }) {
                layerLibrary[index] = reference
            } else {
                layerLibrary.append(reference)
            }
            HTMLLayerStore.save(layerLibrary)

            switch kind {
            case .header:
                sampleHeaderEnabled = false
                headerPath = destination
                canvas.preview.headerBaseURL = destination.deletingLastPathComponent()
                canvas.preview.headerHTML = model.html
                canvas.preview.headerHeight = model.parsedExtent
                UserDefaults.standard.set(reference.id, forKey: "viewdeck.native.active-header-layer")
            case .footer:
                footerPath = destination
                canvas.preview.footerBaseURL = destination.deletingLastPathComponent()
                canvas.preview.footerHTML = model.html
                canvas.preview.footerHeight = model.parsedExtent
                UserDefaults.standard.set(reference.id, forKey: "viewdeck.native.active-footer-layer")
            case .left:
                sampleLeftEnabled = false
                leftPath = destination
                canvas.preview.leftBaseURL = destination.deletingLastPathComponent()
                canvas.preview.leftHTML = model.html
                canvas.preview.leftWidth = model.parsedExtent
                UserDefaults.standard.set(reference.id, forKey: "viewdeck.native.active-left-layer")
            case .right:
                sampleRightEnabled = false
                rightPath = destination
                canvas.preview.rightBaseURL = destination.deletingLastPathComponent()
                canvas.preview.rightHTML = model.html
                canvas.preview.rightWidth = model.parsedExtent
                UserDefaults.standard.set(reference.id, forKey: "viewdeck.native.active-right-layer")
            }
            updateStatus(); rebuildInspector()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The layer could not be saved"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func managedLayerURL(name: String, kind: HTMLLayerKind) throws -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = applicationSupport
            .appendingPathComponent("ViewDeck", isDirectory: true)
            .appendingPathComponent("Layers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let allowed = CharacterSet.alphanumerics
        let words = name.lowercased().components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        let slug = words.joined(separator: "-")
        let base = slug.isEmpty ? kind.rawValue : slug
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return directory.appendingPathComponent("\(base)-\(suffix).html")
    }

    private func restoreSavedLayers() {
        let defaults = UserDefaults.standard
        if let headerID = defaults.string(forKey: "viewdeck.native.active-header-layer") {
            if headerID == "builtin-sample-header" {
                sampleHeaderEnabled = true
                canvas.preview.headerHTML = Self.sampleHeaderHTML
            } else if let layer = layerLibrary.first(where: { $0.id == headerID }),
                      let html = try? String(contentsOf: layer.url, encoding: .utf8) {
                headerPath = layer.url
                canvas.preview.headerBaseURL = layer.url.deletingLastPathComponent()
                canvas.preview.headerHTML = html
            }
        }
        if let footerID = defaults.string(forKey: "viewdeck.native.active-footer-layer"),
           let layer = layerLibrary.first(where: { $0.id == footerID }),
           let html = try? String(contentsOf: layer.url, encoding: .utf8) {
            footerPath = layer.url
            canvas.preview.footerBaseURL = layer.url.deletingLastPathComponent()
            canvas.preview.footerHTML = html
        }
        restoreSavedSideLayer(kind: .left, defaults: defaults)
        restoreSavedSideLayer(kind: .right, defaults: defaults)
        rebuildInspector()
        updateStatus()
    }

    private func restoreSavedSideLayer(kind: HTMLLayerKind, defaults: UserDefaults) {
        guard kind.isSide,
              let identifier = defaults.string(forKey: activeLayerDefaultsKey(kind)) else { return }
        let builtIn = Self.builtInLayer(for: kind)
        if identifier == builtIn?.id {
            if kind == .left {
                sampleLeftEnabled = true
                canvas.preview.leftHTML = builtIn?.html
            } else {
                sampleRightEnabled = true
                canvas.preview.rightHTML = builtIn?.html
            }
            return
        }
        guard let layer = layerLibrary.first(where: { $0.id == identifier && $0.kind == kind }),
              let html = try? String(contentsOf: layer.url, encoding: .utf8) else { return }
        if kind == .left {
            leftPath = layer.url
            canvas.preview.leftBaseURL = layer.url.deletingLastPathComponent()
            canvas.preview.leftHTML = html
        } else {
            rightPath = layer.url
            canvas.preview.rightBaseURL = layer.url.deletingLastPathComponent()
            canvas.preview.rightHTML = html
        }
    }

    private func configureLayerPopup(_ popup: NSPopUpButton, kind: HTMLLayerKind, action: Selector) {
        popup.removeAllItems()
        popup.addItem(withTitle: "None")
        popup.lastItem?.representedObject = "none"
        if let builtIn = Self.builtInLayer(for: kind) {
            popup.addItem(withTitle: builtIn.name)
            popup.lastItem?.representedObject = builtIn.id
        }
        for layer in layerLibrary.filter({ $0.kind == kind }) {
            popup.addItem(withTitle: layer.name)
            popup.lastItem?.representedObject = layer.id
        }
        popup.target = self
        popup.action = action
        popup.toolTip = "Choose the active \(kind.rawValue) layer"
        configureDeckPopup(popup)
        if popup.translatesAutoresizingMaskIntoConstraints {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }
        let builtInEnabled = kind == .header ? sampleHeaderEnabled
            : kind == .left ? sampleLeftEnabled
            : kind == .right ? sampleRightEnabled
            : false
        let activePath = kind == .header ? headerPath?.path
            : kind == .footer ? footerPath?.path
            : kind == .left ? leftPath?.path
            : rightPath?.path
        if builtInEnabled, let builtIn = Self.builtInLayer(for: kind) {
            popup.selectItem(withTitle: builtIn.name)
        } else if let activePath,
                  let active = layerLibrary.first(where: { $0.kind == kind && $0.path == activePath }) {
            popup.selectItem(withTitle: active.name)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @objc private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        setProjectFolder(folder)
    }

    private func restoreSavedProjectFolder() {
        guard let folder = preferences.projectFolderURL else { return }
        setProjectFolder(folder, persist: false)
    }

    private func setProjectFolder(_ folder: URL, persist: Bool = true) {
        let folder = folder.standardizedFileURL
        if projectFolder?.standardizedFileURL != folder {
            pendingServerPreviewIdentity = nil
            if server.state == .running || server.state == .starting { server.stop() }
        }
        projectFolder = folder
        if persist { preferences.projectFolderURL = folder }
        projectButton.title = folder.lastPathComponent
        projectButton.toolTip = "Project folder: \(folder.path)"
        styleButton(projectButton, fill: DeckTheme.card, border: DeckTheme.lineStrong, text: DeckTheme.secondaryText, radius: 10)
        scriptPopup.removeAllItems()
        let scripts = server.scripts(in: folder)
        if scripts.isEmpty { scriptPopup.addItem(withTitle: "No npm scripts found") }
        else { scriptPopup.addItems(withTitles: scripts) }
        scriptPopup.isEnabled = !scripts.isEmpty
        let indexFile = folder.appendingPathComponent("index.html")
        if scripts.isEmpty, FileManager.default.fileExists(atPath: indexFile.path) {
            launchMode = .staticHTML
            staticHTMLFile = indexFile
            serverStatusLabel.stringValue = "Ready to preview index.html"
        } else if scripts.isEmpty {
            launchMode = .customCommand
            serverStatusLabel.stringValue = "Enter a command for \(folder.lastPathComponent)"
        } else {
            launchMode = .npmScript
            serverStatusLabel.stringValue = "Ready to launch \(folder.lastPathComponent)"
        }
        rebuildInspector()
    }

    @objc private func openTerminalForSelectedProject() {
        guard let projectFolder else { return }
        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            presentError(
                title: "Couldn’t open Terminal",
                error: NSError(
                    domain: "ViewDeck",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey: "Terminal.app could not be found."]
                )
            )
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [projectFolder],
            withApplicationAt: terminalURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.presentError(title: "Couldn’t open Terminal", error: error)
            }
        }
    }

    @objc private func launchModeChanged(_ sender: NSPopUpButton) {
        if server.state == .running || server.state == .starting {
            pendingServerPreviewIdentity = nil
            server.stop()
        }
        launchMode = LocalLaunchMode(rawValue: sender.indexOfSelectedItem) ?? .npmScript
        switch launchMode {
        case .npmScript: serverStatusLabel.stringValue = "Choose an npm script to run"
        case .staticHTML: serverStatusLabel.stringValue = staticHTMLFile == nil ? "Choose an HTML file" : "Ready to preview \(staticHTMLFile!.lastPathComponent)"
        case .customCommand: serverStatusLabel.stringValue = "Enter any command to run in the project folder"
        }
        rebuildInspector()
    }

    @objc private func chooseStaticHTML() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.html]
        panel.directoryURL = projectFolder
        guard panel.runModal() == .OK, let file = panel.url else { return }
        staticHTMLFile = file
        projectFolder = file.deletingLastPathComponent().standardizedFileURL
        preferences.projectFolderURL = projectFolder
        projectButton.title = projectFolder?.lastPathComponent ?? "Choose local project"
        previewStaticHTML(file)
        rebuildInspector()
    }

    @objc private func customCommandSubmitted() { toggleServer() }

    @objc private func toggleServer() {
        if server.state == .stopping { return }
        if server.state == .running || server.state == .starting {
            stopLocalProcessAndClearPreview()
            return
        }
        logView.string = ""
        logShowsPlaceholder = false
        switch launchMode {
        case .npmScript:
            guard let projectFolder, scriptPopup.isEnabled, let script = scriptPopup.titleOfSelectedItem else {
                chooseProject(); return
            }
            pendingServerPreviewIdentity = serverPreviewIdentity(
                folder: projectFolder,
                launchDescription: "npm run \(script)"
            )
            do { try server.start(folder: projectFolder, script: script) }
            catch {
                pendingServerPreviewIdentity = nil
                serverStatusLabel.stringValue = error.localizedDescription
                devServerDidOutput(error.localizedDescription, isError: true)
            }
        case .staticHTML:
            guard let staticHTMLFile else {
                chooseStaticHTML()
                return
            }
            previewStaticHTML(staticHTMLFile)
            rebuildInspector()
        case .customCommand:
            guard let projectFolder else {
                chooseProject(); return
            }
            let command = customCommandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                serverStatusLabel.stringValue = "Enter a custom command first"
                devServerDidOutput("Enter a custom command first", isError: true)
                return
            }
            pendingServerPreviewIdentity = serverPreviewIdentity(
                folder: projectFolder,
                launchDescription: command
            )
            do { try server.startCommand(folder: projectFolder, command: command) }
            catch {
                pendingServerPreviewIdentity = nil
                serverStatusLabel.stringValue = error.localizedDescription
                devServerDidOutput(error.localizedDescription, isError: true)
            }
        }
    }

    private func stopLocalProcessAndClearPreview() {
        pendingServerPreviewIdentity = nil
        canvas.preview.showEmptyState()
        server.stop()
    }

    private func serverPreviewIdentity(folder: URL, launchDescription: String) -> String {
        "\(folder.standardizedFileURL.path)\u{0}\(launchMode.rawValue)\u{0}\(launchDescription)"
    }

    private func previewStaticHTML(_ file: URL) {
        serverStatusLabel.stringValue = "Previewing \(file.lastPathComponent)"
        devServerDidOutput("Loaded \(file.path)", isError: false)
        canvas.preview.loadLocalFile(file)
    }

    @objc private func addCurrentDeviceToCustom() {
        guard commitPendingInspectorEdit() else { return }
        let identifier = UUID().uuidString
        var profile = canvas.preview.profile
        profile.id = identifier
        profile.name += profile.builtin ? " Custom" : " Copy"
        profile.builtin = false
        presentCustomDeviceEditor(
            setup: currentCustomSetup(id: identifier, profile: profile),
            replacing: nil
        )
    }

    @objc private func saveSelectedCustomSetup() {
        guard commitPendingInspectorEdit() else { return }
        guard let customIndex = selectedCustomIndex else {
            addCurrentDeviceToCustom()
            return
        }
        let identifier = customSetups[customIndex].id
        var profile = canvas.preview.profile
        profile.id = identifier
        profile.builtin = false
        customSetups[customIndex] = currentCustomSetup(id: identifier, profile: profile)
        CustomDeviceSetupStore.save(customSetups)
        recentlySavedCustomSetupID = identifier
        refreshDeviceLists()
        rebuildInspector()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.recentlySavedCustomSetupID == identifier else { return }
            self.recentlySavedCustomSetupID = nil
            if self.selectedInspectorTab == .device { self.rebuildInspector() }
        }
    }

    private func commitPendingInspectorEdit() -> Bool {
        guard let window else { return true }
        guard let fieldEditor = window.firstResponder as? NSTextView,
              let field = fieldEditor.delegate as? NSTextField,
              field.isDescendant(of: inspectorStack),
              let action = field.action else {
            return window.makeFirstResponder(nil)
        }
        field.validateEditing()
        return NSApp.sendAction(action, to: field.target, from: field)
    }

    @objc private func editSidebarDevice(_ sender: NSMenuItem) {
        guard devices.indices.contains(sender.tag) else { return }
        if sender.tag >= BuiltinDevices.all.count {
            let customIndex = sender.tag - BuiltinDevices.all.count
            let storedSetup = customSetups[customIndex]
            let setup: CustomDeviceSetup
            if sender.tag == selectedIndex {
                var profile = canvas.preview.profile
                profile.id = storedSetup.id
                profile.builtin = false
                setup = currentCustomSetup(id: storedSetup.id, profile: profile)
            } else {
                setup = storedSetup
            }
            presentCustomDeviceEditor(setup: setup, replacing: setup.id)
            return
        }

        let identifier = UUID().uuidString
        var profile = BuiltinDevices.all[sender.tag]
        profile.id = identifier
        profile.name += " Custom"
        profile.builtin = false
        presentCustomDeviceEditor(
            setup: currentCustomSetup(id: identifier, profile: profile),
            replacing: nil
        )
    }

    @objc private func removeSidebarDevice(_ sender: NSMenuItem) {
        removeCustomSetup(at: sender.tag - BuiltinDevices.all.count)
    }

    private func removeCustomSetup(at customIndex: Int) {
        guard customSetups.indices.contains(customIndex) else { return }
        let setup = customSetups[customIndex]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(setup.profile.name)?"
        alert.informativeText = "This removes the saved custom setup. Imported layer files are left intact."
        alert.addButton(withTitle: "Remove custom device")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let removedGlobalIndex = BuiltinDevices.all.count + customIndex
        customSetups.remove(at: customIndex)
        CustomDeviceSetupStore.save(customSetups)
        if selectedIndex == removedGlobalIndex {
            if customSetups.isEmpty {
                selectDevice(at: 0)
            } else {
                selectDevice(at: BuiltinDevices.all.count + min(customIndex, customSetups.count - 1))
            }
        } else {
            if selectedIndex > removedGlobalIndex { selectedIndex -= 1 }
            refreshDeviceLists()
        }
    }

    private func currentCustomSetup(id: String, profile: DeviceProfile) -> CustomDeviceSetup {
        CustomDeviceSetup(
            id: id,
            profile: profile,
            landscape: canvas.preview.landscape,
            header: currentLayerSelection(.header),
            footer: currentLayerSelection(.footer),
            left: currentLayerSelection(.left),
            right: currentLayerSelection(.right)
        )
    }

    private func currentLayerSelection(_ kind: HTMLLayerKind) -> CustomDeviceLayerSelection {
        let identifier: String?
        let extent: CGFloat
        switch kind {
        case .header:
            identifier = sampleHeaderEnabled
                ? Self.builtInLayer(for: kind)?.id
                : layerLibrary.first(where: { $0.kind == kind && $0.path == headerPath?.path })?.id
            extent = canvas.preview.headerHeight
        case .footer:
            identifier = layerLibrary.first(where: { $0.kind == kind && $0.path == footerPath?.path })?.id
            extent = canvas.preview.footerHeight
        case .left:
            identifier = sampleLeftEnabled
                ? Self.builtInLayer(for: kind)?.id
                : layerLibrary.first(where: { $0.kind == kind && $0.path == leftPath?.path })?.id
            extent = canvas.preview.leftWidth
        case .right:
            identifier = sampleRightEnabled
                ? Self.builtInLayer(for: kind)?.id
                : layerLibrary.first(where: { $0.kind == kind && $0.path == rightPath?.path })?.id
            extent = canvas.preview.rightWidth
        }
        return CustomDeviceLayerSelection(identifier: identifier, extent: extent)
    }

    private func presentCustomDeviceEditor(setup: CustomDeviceSetup, replacing id: String?) {
        let model = DeviceEditorModel(setup: setup)
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 590, height: 680),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = id == nil ? "Add custom device" : "Edit custom device"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = DeckTheme.panel
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel

        let editor = DeviceEditorView(
            model: model,
            editing: id != nil,
            layerOptions: deviceEditorLayerOptions(for: setup),
            onSave: { NSApp.stopModal(withCode: .OK) },
            onCancel: { NSApp.stopModal(withCode: .cancel) }
        )
        let host = NSHostingView(rootView: editor)
        host.frame = panel.contentView?.bounds ?? CGRect(x: 0, y: 0, width: 590, height: 680)
        panel.contentView = host
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        guard response == .OK else { return }

        let savedSetup = model.makeSetup()
        if let id, let index = customSetups.firstIndex(where: { $0.id == id }) {
            customSetups[index] = savedSetup
        } else {
            customSetups.append(savedSetup)
        }
        CustomDeviceSetupStore.save(customSetups)
        selectedIndex = BuiltinDevices.all.count
            + (customSetups.firstIndex(where: { $0.id == savedSetup.id }) ?? customSetups.count - 1)
        selectDevice(at: selectedIndex)
    }

    private func deviceEditorLayerOptions(
        for setup: CustomDeviceSetup
    ) -> [HTMLLayerKind: [DeviceEditorLayerOption]] {
        Dictionary(uniqueKeysWithValues: HTMLLayerKind.allCases.map { kind in
            var options = [DeviceEditorLayerOption(id: DeviceEditorModel.noLayerID, title: "None")]
            if let builtIn = Self.builtInLayer(for: kind) {
                options.append(DeviceEditorLayerOption(id: builtIn.id, title: builtIn.name))
            }
            options += layerLibrary
                .filter { $0.kind == kind }
                .map { DeviceEditorLayerOption(id: $0.id, title: $0.name) }
            if let identifier = setup.layer(kind).identifier,
               !options.contains(where: { $0.id == identifier }) {
                options.append(DeviceEditorLayerOption(id: identifier, title: "Missing layer"))
            }
            return (kind, options)
        })
    }

    func previewDidStartLoading() {
        networkActivitySignature = nil
        networkActivitySnapshot = NetworkActivitySnapshot(
            loading: true,
            progress: 0,
            pendingCount: 0,
            completedCount: 0,
            failedCount: 0,
            resources: []
        )
        if selectedInspectorTab == .network {
            renderNetworkActivity(networkActivitySnapshot)
            refreshNetworkActivity()
        }
    }

    func previewDidFinishLoading(title: String?, url: URL?) {
        guard let url else { return }
        let address = url.absoluteString
        addressField.stringValue = address
        toolbarModel.address = address
        UserDefaults.standard.set(address, forKey: "viewdeck.native.last-url")
        if selectedInspectorTab == .network { refreshNetworkActivity() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if let recording = self.pendingQARecording,
               PreviewNavigationPolicy.websiteDataScopesMatch(recording.targetURL, url) {
                self.pendingQARecording = nil
                self.qaRecorder = recording.recorder
                recording.recorder.start(captureVideo: recording.captureVideo)
                self.toolbarModel.isQARecordingReady = true
            }
            if let replay = self.pendingQAReplay,
               self.replaySourceMatches(url, source: replay.scenario.source) {
                self.beginPendingQAReplayIfNeeded()
            }
        }
    }

    func previewDidFail(_ message: String) {
        if pendingQARecording != nil {
            pendingQARecording = nil
            toolbarModel.isQARecording = false
            toolbarModel.isQARecordingReady = false
        }
        devServerDidOutput(message, isError: true)
    }

    func devServerStateChanged(_ state: DevServerState, url: URL?) {
        switch state {
        case .starting, .running:
            toolbarModel.localProcessState = .running
        case .stopping:
            toolbarModel.localProcessState = .stopping
        case .idle, .failed:
            toolbarModel.localProcessState = .idle
        }
        switch state {
        case .idle:
            pendingServerPreviewIdentity = nil
            serverStatusLabel.stringValue = "Server stopped"
            if let source = pendingQAServerLaunch {
                pendingQAServerLaunch = nil
                startRecordedProject(source)
            }
        case .starting:
            canvas.preview.prepareForLocalServerLaunch()
            serverStatusLabel.stringValue = launchMode == .customCommand
                ? "Starting custom command…"
                : "Starting npm run \(scriptPopup.titleOfSelectedItem ?? "dev")…"
        case .running:
            serverStatusLabel.stringValue = launchMode == .customCommand && url == nil
                ? "Custom command is running"
                : "Checking \(url?.absoluteString ?? "server listener…")"
            if let url {
                if let pending = pendingQAReplay {
                    let target = replayURL(serverURL: url, source: pending.scenario.source)
                    addressField.stringValue = target.absoluteString
                    toolbarModel.address = target.absoluteString
                    canvas.preview.loadLocalServer(target.absoluteString, resetSiteData: true)
                } else {
                    addressField.stringValue = url.absoluteString
                    toolbarModel.address = url.absoluteString
                    inspectAndLoadDetectedServer(url)
                }
            }
        case .stopping: serverStatusLabel.stringValue = "Stopping server…"
        case .failed:
            pendingServerPreviewIdentity = nil
            serverStatusLabel.stringValue = "Server exited with an error"
        }
        if selectedInspectorTab == .server { rebuildInspector() }
    }

    private func inspectAndLoadDetectedServer(_ url: URL) {
        let nextIdentity = pendingServerPreviewIdentity
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try LocalhostPortScanner.scan() }
            DispatchQueue.main.async {
                guard let self,
                      self.server.state == .running,
                      self.server.serverURL == url else { return }

                if case .success(let processes) = result {
                    self.localhostProcesses = processes
                    self.localhostScanError = nil
                    if let port = url.port {
                        let owners = processes.filter { $0.ports.contains(port) }
                        if Set(owners.map(\.pid)).count > 1 {
                            let names = owners.map { "\($0.displayName) (PID \($0.pid))" }.joined(separator: ", ")
                            self.pendingServerPreviewIdentity = nil
                            self.serverStatusLabel.stringValue = "Port \(port) collision · open Ports"
                            self.devServerDidOutput(
                                "Port \(port) is shared by \(names). ViewDeck did not open an ambiguous localhost URL.",
                                isError: true
                            )
                            if self.selectedInspectorTab == .server || self.selectedInspectorTab == .ports {
                                self.rebuildInspector()
                            }
                            return
                        }
                    }
                } else if case .failure(let error) = result {
                    self.localhostScanError = error.localizedDescription
                }

                self.serverStatusLabel.stringValue = "Server is live · \(url.absoluteString)"
                self.canvas.preview.loadLocalServer(
                    url.absoluteString,
                    resetSiteData: nextIdentity != nil && nextIdentity != self.activeServerPreviewIdentity
                )
                self.activeServerPreviewIdentity = nextIdentity ?? self.activeServerPreviewIdentity
                self.pendingServerPreviewIdentity = nil
                if self.selectedInspectorTab == .server || self.selectedInspectorTab == .ports {
                    self.rebuildInspector()
                }
            }
        }
    }

    func devServerDidOutput(_ line: String, isError: Bool) {
        if logShowsPlaceholder {
            logView.string = ""
            logShowsPlaceholder = false
        }
        let prefix = isError ? "! " : "› "
        let append = NSAttributedString(string: prefix + line + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: isError ? NSColor(hex: 0xff766e) : NSColor(hex: 0x99a4ac)
        ])
        logView.textStorage?.append(append)
        logView.scrollToEndOfDocument(nil)
    }

    private func restoreSplitPositions() {
        splitView.layoutSubtreeIfNeeded()
        defer { hasRestoredSplitPositions = true }
        guard splitView.bounds.width > sidebarMinimumWidth + inspectorMinimumWidth + centerMinimumWidth else { return }

        let defaults = UserDefaults.standard
        let savedInspector = defaults.object(forKey: SplitPreferenceKey.inspectorWidth) as? NSNumber
        let inspectorWidth = min(640, max(inspectorMinimumWidth, CGFloat(savedInspector?.doubleValue ?? Double(inspectorInitialWidth))))

        restoringSplitPositions = true
        splitView.setPosition(preferredSidebarWidth, ofDividerAt: 0)
        splitView.setPosition(splitView.bounds.width - inspectorWidth - splitView.dividerThickness, ofDividerAt: 1)
        setSidebarCollapsed(defaults.bool(forKey: SplitPreferenceKey.sidebarCollapsed), persist: false)
        restoringSplitPositions = false
    }

    private var preferredSidebarWidth: CGFloat {
        let savedWidth = UserDefaults.standard.object(forKey: SplitPreferenceKey.sidebarWidth) as? NSNumber
        return min(440, max(sidebarMinimumWidth, CGFloat(savedWidth?.doubleValue ?? Double(sidebarInitialWidth))))
    }

    private var sidebarIsCollapsed: Bool {
        !splitView.arrangedSubviews.contains { $0 === sidebar }
    }

    private func setSidebarCollapsed(_ collapsed: Bool, persist: Bool) {
        guard collapsed != sidebarIsCollapsed else {
            toolbarModel.isSidebarCollapsed = collapsed
            if persist {
                UserDefaults.standard.set(collapsed, forKey: SplitPreferenceKey.sidebarCollapsed)
            }
            return
        }

        if collapsed {
            if sidebar.frame.width >= sidebarMinimumWidth {
                UserDefaults.standard.set(Double(sidebar.frame.width), forKey: SplitPreferenceKey.sidebarWidth)
            }
            sidebarMinimumWidthConstraint?.isActive = false
            sidebar.isHidden = true
            splitView.removeArrangedSubview(sidebar)
            splitView.adjustSubviews()
        } else {
            sidebar.isHidden = false
            splitView.insertArrangedSubview(sidebar, at: 0)
            sidebarMinimumWidthConstraint?.isActive = true
            splitView.adjustSubviews()
            splitView.setPosition(preferredSidebarWidth, ofDividerAt: 0)
        }

        toolbarModel.isSidebarCollapsed = collapsed
        if persist {
            UserDefaults.standard.set(collapsed, forKey: SplitPreferenceKey.sidebarCollapsed)
        }
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === center
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if !sidebarIsCollapsed, dividerIndex == 0 {
            return max(sidebarMinimumWidth, proposedMinimumPosition)
        }
        let centerLeadingEdge = sidebarIsCollapsed
            ? splitView.bounds.minX
            : sidebar.frame.maxX + splitView.dividerThickness
        let minimumCenterEdge = centerLeadingEdge + centerMinimumWidth
        return max(minimumCenterEdge, proposedMinimumPosition)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let inspectorDividerIndex = sidebarIsCollapsed ? 0 : 1
        if dividerIndex == inspectorDividerIndex {
            return min(splitView.bounds.width - inspectorMinimumWidth - splitView.dividerThickness, proposedMaximumPosition)
        }
        let maximumSidebarEdge = inspector.frame.minX - splitView.dividerThickness - centerMinimumWidth
        return min(maximumSidebarEdge, proposedMaximumPosition)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        let collapsed = sidebarIsCollapsed
        toolbarModel.isSidebarCollapsed = collapsed
        guard hasRestoredSplitPositions, !restoringSplitPositions else { return }

        UserDefaults.standard.set(collapsed, forKey: SplitPreferenceKey.sidebarCollapsed)
        guard !collapsed,
              sidebar.frame.width >= sidebarMinimumWidth,
              inspector.frame.width >= inspectorMinimumWidth else { return }
        UserDefaults.standard.set(Double(sidebar.frame.width), forKey: SplitPreferenceKey.sidebarWidth)
        UserDefaults.standard.set(Double(inspector.frame.width), forKey: SplitPreferenceKey.inspectorWidth)
    }

    private func styleButton(_ button: NSButton, fill: NSColor, border: NSColor, text: NSColor, radius: CGFloat) {
        button.isBordered = false
        button.focusRingType = .none
        button.wantsLayer = true
        button.layer?.backgroundColor = fill.cgColor
        button.layer?.borderColor = border.cgColor
        button.layer?.borderWidth = border.alphaComponent > 0 ? 1 : 0
        button.layer?.cornerRadius = radius
        button.contentTintColor = text
        button.image?.isTemplate = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = button.alignment
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .font: button.font ?? NSFont.systemFont(ofSize: 10),
            .foregroundColor: text,
            .paragraphStyle: paragraph
        ])
        if let button = button as? DeckButton {
            button.baseFill = fill
            button.hoverFill = fill.blended(withFraction: 0.12, of: .white) ?? DeckTheme.hover
            button.pressedFill = fill.blended(withFraction: 0.10, of: .black) ?? fill
            button.stroke = border
            button.cornerRadius = radius
            button.updateDeckAppearance()
        }
    }

    private func applySidebarSelection(_ button: NSButton, selected: Bool) {
        styleButton(
            button,
            fill: selected ? DeckTheme.selected : .clear,
            border: selected ? DeckTheme.accentLine : .clear,
            text: selected ? DeckTheme.accentBright : DeckTheme.muted,
            radius: 8
        )
    }

    private func configureNumberField(_ field: NSTextField, action: Selector) {
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        field.target = self
        field.action = action
        configureDeckField(field, centered: true)
        field.translatesAutoresizingMaskIntoConstraints = false
    }

    private func inspectorNumberField(_ value: CGFloat, action: Selector) -> NSTextField {
        let field = NSTextField(string: value.formatted())
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        field.target = self
        field.action = action
        field.cell?.sendsActionOnEndEditing = true
        configureDeckField(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 96).isActive = true
        field.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return field
    }

    private func inspectorTextField(_ value: String, action: Selector) -> NSTextField {
        let field = NSTextField(string: value)
        field.font = .systemFont(ofSize: 10.5, weight: .medium)
        field.target = self
        field.action = action
        field.cell?.sendsActionOnEndEditing = true
        field.cell?.lineBreakMode = .byTruncatingTail
        configureDeckField(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 160).isActive = true
        field.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return field
    }

    private func inspectorPopup(
        values: [String],
        selected: String,
        action: Selector
    ) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: values)
        popup.selectItem(withTitle: selected)
        popup.target = self
        popup.action = action
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 10.5, weight: .medium)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        popup.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return popup
    }

    private func makeSidebarButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = DeckButton(frame: .zero)
        button.title = title
        button.target = self
        button.action = action
        button.toolTip = title
        button.setButtonType(.pushOnPushOff)
        button.alignment = .left
        button.font = .systemFont(ofSize: 11.5, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        styleButton(button, fill: .clear, border: .clear, text: DeckTheme.muted, radius: 8)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func makeIconButton(_ title: String, tooltip: String, action: Selector) -> NSButton {
        let button = DeckButton(frame: .zero)
        button.title = title
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.font = .systemFont(ofSize: 14, weight: .medium)
        styleButton(button, fill: .clear, border: .clear, text: DeckTheme.muted, radius: 7)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func makeSmallButton(_ title: String, action: Selector) -> NSButton {
        let button = DeckButton(frame: .zero)
        button.title = title
        button.target = self
        button.action = action
        button.toolTip = title
        button.font = .systemFont(ofSize: 11, weight: .medium)
        styleButton(button, fill: NSColor.white.withAlphaComponent(0.025), border: DeckTheme.line, text: DeckTheme.secondaryText, radius: 7)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func makeAccentButton(_ title: String, action: Selector) -> NSButton {
        let button = DeckButton(frame: .zero)
        button.title = title
        button.target = self
        button.action = action
        button.toolTip = title
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        styleButton(button, fill: DeckTheme.accent, border: DeckTheme.accentBright, text: NSColor(hex: 0x152006), radius: 8)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func makeWideButton(_ title: String, action: Selector) -> NSButton {
        let button = DeckButton(frame: .zero)
        button.title = title
        button.target = self
        button.action = action
        button.toolTip = title
        button.alignment = .left
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.font = .systemFont(ofSize: 11, weight: .medium)
        styleButton(button, fill: DeckTheme.card, border: DeckTheme.lineStrong, text: DeckTheme.secondaryText, radius: 9)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        return button
    }

    private func sectionLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
        label.textColor = DeckTheme.muted
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func inspectorHeading(_ title: String, subtitle: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.textColor = DeckTheme.text
        let detail = helpText(subtitle)
        stack.addArrangedSubview(heading); stack.addArrangedSubview(detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func formRow(_ labelValue: String, field: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal; row.alignment = .centerY; row.distribution = .fill
        let label = NSTextField(labelWithString: labelValue)
        label.textColor = DeckTheme.muted
        label.font = .systemFont(ofSize: 11, weight: .medium)
        if let textField = field as? NSTextField, textField.isEditable {
            textField.toolTip = "Edit \(labelValue.lowercased())"
        }
        row.addArrangedSubview(label); row.addArrangedSubview(field)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func infoRow(_ labelValue: String, value: String) -> NSView {
        formRow(labelValue, field: inspectorInfoField(value))
    }

    private func inspectorInfoField(_ value: String) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.alignment = .right
        field.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        field.textColor = DeckTheme.secondaryText
        return field
    }

    private func helpText(_ value: String) -> NSTextField {
        let text = NSTextField(wrappingLabelWithString: value)
        text.font = .systemFont(ofSize: 10.5, weight: .regular)
        text.textColor = DeckTheme.muted
        text.translatesAutoresizingMaskIntoConstraints = false
        return text
    }

    private func inspectorCard(_ views: [NSView], spacing: CGFloat = 10) -> NSView {
        let card = DeckCardView(views: views, spacing: spacing)
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    private func cardDivider() -> NSView {
        let divider = FlippedView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DeckTheme.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    private static func layerTemplate(kind: HTMLLayerKind) -> String {
        let alignment: String
        let title: String
        let bodyLayout: String
        switch kind {
        case .header:
            alignment = "border-bottom"
            title = "h5_header"
            bodyLayout = "align-items: center; padding: 0 16px;"
        case .footer:
            alignment = "border-top"
            title = "h5_footer"
            bodyLayout = "align-items: center; padding: 0 16px;"
        case .left:
            alignment = "border-right"
            title = "h5_left"
            bodyLayout = "align-items: center; justify-content: center; writing-mode: vertical-rl;"
        case .right:
            alignment = "border-left"
            title = "h5_right"
            bodyLayout = "align-items: center; justify-content: center; writing-mode: vertical-rl;"
        }
        return """
        <!doctype html>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          * { box-sizing: border-box; }
          html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; }
          body {
            display: flex;
            \(bodyLayout)
            background: #0a0d11;
            color: #f0f3f5;
            font: 600 15px -apple-system, BlinkMacSystemFont, sans-serif;
            \(alignment): 1px solid rgba(255,255,255,.12);
          }
        </style>
        <body>\(title)</body>
        """
    }

    private static func builtInLayer(for kind: HTMLLayerKind) -> (id: String, name: String, html: String)? {
        switch kind {
        case .header:
            ("builtin-sample-header", "h5_header", sampleHeaderHTML)
        case .footer:
            nil
        case .left:
            ("builtin-reference-left-rail", "h5_left", referenceLeftRailHTML)
        case .right:
            ("builtin-reference-right-rail", "h5_right", referenceRightRailHTML)
        }
    }

    private static let sampleHeaderHTML = """
    <!doctype html><title>h5_header</title><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>*{box-sizing:border-box}html,body{width:100%;height:100%;margin:0;overflow:hidden;background:#050505;color:#d8d9db;font-family:-apple-system}header{height:100%;display:flex;align-items:center;gap:13px;padding:0 14px;border-bottom:1px solid #242629}.menu{font-size:21px;color:white}.info{font-size:18px}.title{flex:1;font-size:16px;white-space:nowrap}.actions{display:flex;gap:16px;color:#8b8d91;font-size:18px}.like{color:white}</style>
    <header><span class="menu">☰</span><span class="info">ⓘ</span><span class="title">Preview App</span><span class="actions"><span class="like">♥</span><span>⌯</span><span>□</span><span>⋮</span></span></header>
    """

    private static let referenceLeftRailHTML = """
    <!doctype html><title>h5_left</title><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
    *{box-sizing:border-box}html,body{width:100%;height:100%;margin:0;overflow:hidden;background:#070707;color:#57595c;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
    .rail{position:relative;width:100%;height:100%;border-right:1px solid rgba(255,255,255,.025)}
    .item{position:absolute;left:76%;display:grid;place-items:center;transform:translate(-50%,-50%);color:#57595c}
    .menu{top:5.7%}.app-icon{top:16.4%;width:34%;aspect-ratio:1;border-radius:9px;background:#62615b;box-shadow:0 0 0 1px rgba(255,255,255,.04)}
    .search{top:27.4%}.discover{top:38%}svg{display:block;max-width:100%;max-height:100%}
    </style>
    <nav class="rail" aria-label="Primary">
      <span class="item menu" aria-label="Menu"><svg width="14" height="11" viewBox="0 0 28 22" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round"><path d="M2 2h24M2 11h24M2 20h24"/></svg></span>
      <span class="item app-icon" aria-label="Blank app icon"></span>
      <span class="item search" aria-label="Search"><svg width="17" height="17" viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="2.7"><circle cx="12" cy="12" r="9"/><path d="m19 19 7 7"/></svg></span>
      <span class="item discover" aria-label="Discover"><svg width="18" height="18" viewBox="0 0 30 30" fill="none" stroke="currentColor" stroke-width="2.6"><circle cx="15" cy="15" r="12"/><path d="m20 10-3 8-8 3 3-8 8-3Z"/></svg></span>
    </nav>
    """

    private static let referenceRightRailHTML = """
    <!doctype html><title>h5_right</title><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
    *{box-sizing:border-box}html,body{width:100%;height:100%;margin:0;overflow:hidden;background:#070707;color:#57595c;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
    .rail{position:relative;width:100%;height:100%;border-left:1px solid rgba(255,255,255,.025)}
    button{position:absolute;left:24%;display:grid;place-items:center;width:54%;aspect-ratio:1;transform:translate(-50%,-50%);padding:0;border:0;background:transparent;color:#57595c}
    button:focus-visible{outline:2px solid #b8ee55;outline-offset:4px;border-radius:8px}.like{top:5.7%}.share{top:16%}.comment{top:26.3%}.more{top:36.8%}svg{display:block;max-width:17px;max-height:17px}
    </style>
    <aside class="rail" aria-label="Page actions">
      <button class="like" type="button" aria-label="Like"><svg viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linejoin="round"><path d="M10 28H5V13h5v15Zm0-13 6-11c1-2 4-.6 3.4 1.7L18 11h7.5c2.2 0 3.8 2 3.2 4.1l-2.7 10A4 4 0 0 1 22.2 28H10V15Z"/></svg></button>
      <button class="share" type="button" aria-label="Share"><svg viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="2.6"><circle cx="24" cy="7" r="3.5"/><circle cx="8" cy="16" r="3.5"/><circle cx="24" cy="25" r="3.5"/><path d="m11 14 10-5.5M11 18l10 5.5"/></svg></button>
      <button class="comment" type="button" aria-label="Comment"><svg viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linejoin="round"><path d="M5 6h22v16H12l-7 6V6Z"/></svg></button>
      <button class="more" type="button" aria-label="More"><svg viewBox="0 0 32 32" fill="currentColor"><circle cx="16" cy="7" r="2.4"/><circle cx="16" cy="16" r="2.4"/><circle cx="16" cy="25" r="2.4"/></svg></button>
    </aside>
    """
}
