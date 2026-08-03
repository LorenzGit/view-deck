import AppKit
import Foundation
import SwiftUI

enum ViewDeckAgentWorkflow: String, CaseIterable, Identifiable {
    case capture = "Capture screenshot"
    case inspect = "Inspect only"
    case record = "Record video"
    case qaScenario = "Author and replay QA scenario"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .capture:
            "Capture the requested state, inspect the report, and visually review the screenshot."
        case .inspect:
            "Run a report-driven audit without requiring a screenshot."
        case .record:
            "Record the requested state or animation, then inspect the video and report."
        case .qaScenario:
            "Generate a QA template, author deterministic events and checkpoints, replay it, and inspect every artifact."
        }
    }
}

enum ViewDeckAgentSourceKind: String, CaseIterable, Identifiable {
    case url = "URL"
    case project = "Local project"
    case htmlFile = "Static HTML file"

    var id: String { rawValue }
}

enum ViewDeckAgentProjectLaunch: String, CaseIterable, Identifiable {
    case npmScript = "NPM script"
    case customCommand = "Custom command"

    var id: String { rawValue }
}

enum ViewDeckAgentOrientation: String, CaseIterable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }
}

struct ViewDeckAgentLayerConfiguration: Equatable {
    var name: String
    var path: String
    var extent: String
    var isSelected: Bool

    static func empty(_ kind: HTMLLayerKind) -> ViewDeckAgentLayerConfiguration {
        ViewDeckAgentLayerConfiguration(
            name: "",
            path: "",
            extent: ViewDeckAgentPromptConfiguration.number(kind.defaultExtent),
            isSelected: false
        )
    }
}

struct ViewDeckAgentPromptConfiguration: Equatable {
    var objective = "Inspect this experience and report visual, layout, runtime, and interaction issues. Iterate when useful and return evidence for every conclusion."
    var workflow = ViewDeckAgentWorkflow.capture
    var executablePath = ""

    var sourceKind: ViewDeckAgentSourceKind
    var sourceValue: String
    var projectLaunch = ViewDeckAgentProjectLaunch.npmScript
    var npmScript = "dev"
    var customCommand = ""
    var route = ""

    var deviceID: String
    var deviceName: String
    var orientation: ViewDeckAgentOrientation
    var showSafeArea: Bool
    var applySafeArea: Bool
    var showPreview = false
    var header: ViewDeckAgentLayerConfiguration
    var footer: ViewDeckAgentLayerConfiguration
    var left: ViewDeckAgentLayerConfiguration
    var right: ViewDeckAgentLayerConfiguration

    var waitSelector = ""
    var waitJavaScript = ""
    var prepareJavaScript = ""
    var delay = "0.5"
    var timeout = "30"

    var networkEnabled: Bool
    var networkRTT: String
    var networkJitter: String
    var networkDown: String
    var networkUp: String
    var networkOffline: Bool
    var networkSeed: String

    var captureOutput = "capture.png"
    var recordingOutput = "recording.mp4"
    var screenshotOutput = ""
    var videoOutput = ""
    var reportOutput = "report.json"
    var scenarioOutput = "scenario.viewdeck.json"
    var scenarioName = "ViewDeck QA"
    var checkpointDirectory = "checkpoints"
    var captureScale = ""
    var videoScale = "1"
    var duration = "5"
    var fps = "30"
    var replaySpeed = "smart"
    var overwrite = true
    var failOnPageError = true
    var failOnIssues = false
    var json = true

    var additionalCLIArguments = ""
    var additionalInstructions = ""

    init(
        setup: CustomDeviceSetup,
        sourceKind: ViewDeckAgentSourceKind,
        sourceValue: String,
        projectLaunch: ViewDeckAgentProjectLaunch = .npmScript,
        launchValue: String = "dev",
        layers: [HTMLLayerKind: ViewDeckAgentLayerConfiguration] = [:],
        network: NetworkShapingConfiguration = .disabled
    ) {
        self.sourceKind = sourceKind
        self.sourceValue = sourceValue
        self.projectLaunch = projectLaunch
        if projectLaunch == .npmScript {
            npmScript = launchValue.isEmpty ? "dev" : launchValue
            customCommand = ""
        } else {
            npmScript = "dev"
            customCommand = launchValue
        }
        deviceID = setup.profile.id
        deviceName = setup.profile.name
        orientation = setup.landscape ? .landscape : .portrait
        showSafeArea = setup.showSafeArea
        applySafeArea = setup.applySafeAreaToPage
        header = layers[.header] ?? .empty(.header)
        footer = layers[.footer] ?? .empty(.footer)
        left = layers[.left] ?? .empty(.left)
        right = layers[.right] ?? .empty(.right)
        networkEnabled = network.enabled
        networkRTT = Self.number(network.roundTripTimeMilliseconds)
        networkJitter = Self.number(network.jitterMilliseconds)
        networkDown = Self.number(network.downloadKilobitsPerSecond)
        networkUp = Self.number(network.uploadKilobitsPerSecond)
        networkOffline = network.offline
        networkSeed = String(network.seed)
    }

    static func number<T: BinaryFloatingPoint>(_ value: T) -> String {
        let numeric = Double(value)
        if numeric.rounded() == numeric { return String(Int(numeric)) }
        return String(format: "%.3f", numeric)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }

    subscript(layer kind: HTMLLayerKind) -> ViewDeckAgentLayerConfiguration {
        get {
            switch kind {
            case .header: header
            case .footer: footer
            case .left: left
            case .right: right
            }
        }
        set {
            switch kind {
            case .header: header = newValue
            case .footer: footer = newValue
            case .left: left = newValue
            case .right: right = newValue
            }
        }
    }
}

enum ViewDeckAgentPromptBuilder {
    static func prompt(for configuration: ViewDeckAgentPromptConfiguration) -> String {
        let objective = trimmed(configuration.objective).isEmpty
            ? "Run deterministic visual and interaction QA on the configured source."
            : trimmed(configuration.objective)
        let executable = trimmed(configuration.executablePath).isEmpty
            ? "Resolve ViewDeck according to the skill (prefer `dist/native/viewdeck` in a ViewDeck checkout)."
            : "Use the ViewDeck executable at `\(trimmed(configuration.executablePath))`."
        let visibility = configuration.showPreview
            ? "visible (`--show-preview`); do not use silent verification"
            : "hidden; pass `--audio verify-silent` and verify the report proves the window stayed offscreen"

        var lines = [
            "Use the `viewdeck-qa` skill and the ViewDeck CLI to complete this task:",
            "",
            objective,
            "",
            "Target configuration:",
            "- Device: \(configuration.deviceName) (`\(configuration.deviceID)`)",
            "- Orientation: \(configuration.orientation.rawValue)",
            "- Source: \(sourceDescription(configuration))",
            "- Workflow: \(configuration.workflow.rawValue). \(configuration.workflow.summary)",
            "- Preview: \(visibility)",
            "",
            "Requested CLI configuration:",
            "```sh",
            commandDraft(configuration),
            "```",
            "",
            "Execution requirements:",
            "- \(executable)",
            "- Run `capabilities --json` and `devices list --json` as preflight, and confirm the requested device ID and required capabilities are supported.",
            "- Resolve source, layer, scenario, and output paths to absolute paths. Create a unique artifact directory with `mktemp -d /tmp/viewdeck-qa.XXXXXX` when an explicit absolute output directory was not supplied.",
            "- Keep the selected orientation immutable for each run. For a QA scenario, generate the template with this orientation; never edit only the scenario orientation string.",
            "- Prefer semantic readiness checks over arbitrary delays. Treat process status, the JSON report, and visual artifacts as evidence.",
            "- Inspect every requested PNG and MP4. Report the effective device, orientation, layout layers, safe-area behavior, network conditions, preview visibility, report path, and artifact paths.",
            "- Do not stop at drafting commands: run the workflow, evaluate the results, and concisely report failures or warnings."
        ]

        let selectedEmbeddedLayers = HTMLLayerKind.allCases.compactMap { kind -> String? in
            let layer = configuration[layer: kind]
            guard layer.isSelected, trimmed(layer.path).isEmpty, !trimmed(layer.name).isEmpty else { return nil }
            return "\(kind.rawValue) ‘\(layer.name)’"
        }
        if !selectedEmbeddedLayers.isEmpty {
            lines.append("- The app setup selected embedded layer(s) without a CLI file path: \(selectedEmbeddedLayers.joined(separator: ", ")). Ask for or create equivalent absolute HTML files before claiming the CLI reproduced them.")
        }

        if configuration.networkEnabled {
            lines.append("- Verify the report's effective network object and traffic evidence. State that shaping covers proxied TCP traffic, not HTTP/3/QUIC or packet loss.")
        }

        let additional = trimmed(configuration.additionalInstructions)
        if !additional.isEmpty {
            lines += ["", "Additional instructions:", additional]
        }
        return lines.joined(separator: "\n")
    }

    static func commandDraft(_ configuration: ViewDeckAgentPromptConfiguration) -> String {
        let executable = trimmed(configuration.executablePath).isEmpty
            ? "<viewdeck>"
            : shellQuote(trimmed(configuration.executablePath))

        if configuration.workflow == .qaScenario {
            let template = renderCommand(
                executable: executable,
                command: ["qa", "template"],
                arguments: templateArguments(configuration)
            )
            let replay = renderCommand(
                executable: executable,
                command: ["qa", "replay", artifactPath(configuration.scenarioOutput, fallback: "scenario.viewdeck.json")],
                arguments: replayArguments(configuration)
            )
            return "\(template)\n\n# Author events/checkpoints from the generated template, then replay it.\n\(replay)"
        }

        let command: String
        switch configuration.workflow {
        case .capture: command = "capture"
        case .inspect: command = "inspect"
        case .record: command = "record"
        case .qaScenario: command = "qa template"
        }
        return renderCommand(
            executable: executable,
            command: [command],
            arguments: directArguments(configuration)
        )
    }

    private static func directArguments(_ configuration: ViewDeckAgentPromptConfiguration) -> [String] {
        var arguments = sourceArguments(configuration)
        arguments += layoutArguments(configuration)
        arguments += readinessArguments(configuration)
        arguments += previewArguments(configuration)
        arguments += networkArguments(configuration)

        switch configuration.workflow {
        case .capture:
            arguments += option("--output", artifactPath(configuration.captureOutput, fallback: "capture.png"))
        case .inspect:
            break
        case .record:
            arguments += option("--output", artifactPath(configuration.recordingOutput, fallback: "recording.mp4"))
        case .qaScenario:
            break
        }

        arguments += optionIfPresent("--screenshot", outputPath(configuration.screenshotOutput))
        arguments += optionIfPresent("--video", outputPath(configuration.videoOutput))
        arguments += optionIfPresent("--report", outputPath(configuration.reportOutput))
        arguments += optionIfPresent("--scale", configuration.captureScale)
        arguments += optionIfPresent("--video-scale", configuration.videoScale)
        if !trimmed(configuration.videoOutput).isEmpty || configuration.workflow == .record {
            arguments += optionIfPresent("--duration", configuration.duration)
            arguments += optionIfPresent("--fps", configuration.fps)
        }
        arguments += policyArguments(configuration)
        return arguments
    }

    private static func templateArguments(_ configuration: ViewDeckAgentPromptConfiguration) -> [String] {
        var arguments = sourceArguments(configuration)
        arguments += layoutArguments(configuration)
        arguments += networkArguments(configuration)
        arguments += optionIfPresent("--name", configuration.scenarioName)
        arguments += option("--output", artifactPath(configuration.scenarioOutput, fallback: "scenario.viewdeck.json"))
        if configuration.overwrite { arguments.append("--overwrite") }
        if configuration.json { arguments.append("--json") }
        arguments += rawAdditionalArguments(configuration)
        return arguments
    }

    private static func replayArguments(_ configuration: ViewDeckAgentPromptConfiguration) -> [String] {
        var arguments = previewArguments(configuration)
        arguments += optionIfPresent("--speed", configuration.replaySpeed)
        arguments += optionIfPresent("--artifacts", outputPath(configuration.checkpointDirectory))
        arguments += optionIfPresent("--screenshot", outputPath(configuration.screenshotOutput))
        arguments += optionIfPresent("--video", outputPath(configuration.videoOutput))
        arguments += optionIfPresent("--report", outputPath(configuration.reportOutput))
        arguments += optionIfPresent("--scale", configuration.captureScale)
        arguments += optionIfPresent("--video-scale", configuration.videoScale)
        if !trimmed(configuration.videoOutput).isEmpty {
            arguments += optionIfPresent("--fps", configuration.fps)
        }
        arguments += policyArguments(configuration)
        return arguments
    }

    private static func sourceArguments(_ configuration: ViewDeckAgentPromptConfiguration) -> [String] {
        let source = trimmed(configuration.sourceValue)
        var arguments: [String]
        switch configuration.sourceKind {
        case .url:
            arguments = [source.isEmpty ? "<url>" : shellQuote(source)]
        case .htmlFile:
            arguments = option("--file", source.isEmpty ? "<absolute-index.html>" : shellQuote(source))
        case .project:
            arguments = option("--project", source.isEmpty ? "<absolute-project-folder>" : shellQuote(source))
            switch configuration.projectLaunch {
            case .npmScript:
                arguments += optionIfPresent("--npm-script", configuration.npmScript)
            case .customCommand:
                arguments += optionIfPresent("--command", configuration.customCommand)
            }
        }
        arguments += optionIfPresent("--path", configuration.route)
        return arguments
    }

    private static func layoutArguments(_ configuration: ViewDeckAgentPromptConfiguration) -> [String] {
        var arguments = option("--device", shellQuote(configuration.deviceID))
        arguments += option("--orientation", configuration.orientation.rawValue)
        if configuration.showSafeArea { arguments.append("--show-safe-area") }
        if configuration.applySafeArea { arguments.append("--apply-safe-area") }
        for kind in HTMLLayerKind.allCases {
            let layer = configuration[layer: kind]
            guard layer.isSelected, !trimmed(layer.path).isEmpty else { continue }
            arguments += option("--\(kind.rawValue)", shellQuote(trimmed(layer.path)))
            arguments += option("--\(kind.rawValue)-\(kind.reservedDimension)", trimmed(layer.extent))
        }
        return arguments
    }

    private static func readinessArguments(_ configuration: ViewDeckAgentPromptConfiguration) -> [String] {
        var arguments = optionIfPresent("--wait-for", configuration.waitSelector)
        arguments += optionIfPresent("--wait-js", configuration.waitJavaScript)
        arguments += optionIfPresent("--prepare-js", configuration.prepareJavaScript)
        arguments += optionIfPresent("--delay", configuration.delay)
        arguments += optionIfPresent("--timeout", configuration.timeout)
        return arguments
    }

    private static func previewArguments(_ configuration: ViewDeckAgentPromptConfiguration) -> [String] {
        if configuration.showPreview { return ["--show-preview"] }
        return option("--audio", "verify-silent")
    }

    private static func networkArguments(_ configuration: ViewDeckAgentPromptConfiguration) -> [String] {
        guard configuration.networkEnabled else { return [] }
        var arguments = optionIfPresent("--network-rtt-ms", configuration.networkRTT)
        arguments += optionIfPresent("--network-jitter-ms", configuration.networkJitter)
        arguments += optionIfPresent("--network-down-kbps", configuration.networkDown)
        arguments += optionIfPresent("--network-up-kbps", configuration.networkUp)
        if configuration.networkOffline { arguments.append("--network-offline") }
        arguments += optionIfPresent("--network-seed", configuration.networkSeed)
        if arguments.isEmpty { arguments.append("--network-enable") }
        return arguments
    }

    private static func policyArguments(_ configuration: ViewDeckAgentPromptConfiguration) -> [String] {
        var arguments: [String] = []
        if configuration.overwrite { arguments.append("--overwrite") }
        if configuration.failOnPageError { arguments.append("--fail-on-page-error") }
        if configuration.failOnIssues { arguments.append("--fail-on-issues") }
        if configuration.json { arguments.append("--json") }
        arguments += rawAdditionalArguments(configuration)
        return arguments
    }

    private static func rawAdditionalArguments(_ configuration: ViewDeckAgentPromptConfiguration) -> [String] {
        let value = trimmed(configuration.additionalCLIArguments)
        return value.isEmpty ? [] : [value]
    }

    private static func sourceDescription(_ configuration: ViewDeckAgentPromptConfiguration) -> String {
        let source = trimmed(configuration.sourceValue)
        let value = source.isEmpty ? "not yet specified" : "`\(source)`"
        if configuration.sourceKind == .project {
            let launch = configuration.projectLaunch == .npmScript
                ? "npm script `\(trimmed(configuration.npmScript).isEmpty ? "dev" : trimmed(configuration.npmScript))`"
                : "custom command `\(trimmed(configuration.customCommand))`"
            return "local project \(value), launched with \(launch)"
        }
        return "\(configuration.sourceKind.rawValue.lowercased()) \(value)"
    }

    private static func renderCommand(executable: String, command: [String], arguments: [String]) -> String {
        let parts = [executable] + command + arguments
        guard let first = parts.first else { return "" }
        let continuation = " \\" + "\n  "
        return ([first] + parts.dropFirst().map { continuation + $0 }).joined()
    }

    private static func option(_ flag: String, _ value: String) -> [String] {
        [flag, value]
    }

    private static func optionIfPresent(_ flag: String, _ value: String) -> [String] {
        let value = trimmed(value)
        return value.isEmpty ? [] : option(flag, shellQuote(value))
    }

    private static func outputPath(_ value: String) -> String {
        let value = trimmed(value)
        guard !value.isEmpty else { return "" }
        return artifactPath(value, fallback: value)
    }

    private static func artifactPath(_ value: String, fallback: String) -> String {
        let value = trimmed(value).isEmpty ? fallback : trimmed(value)
        if value.hasPrefix("/") { return shellQuote(value) }
        return "\"$ARTIFACT_DIR/\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func shellQuote(_ value: String) -> String {
        if value.hasPrefix("<") && value.hasSuffix(">") { return value }
        if value.hasPrefix("\"") && value.hasSuffix("\"") { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class ViewDeckAgentPromptModel: ObservableObject {
    @Published var configuration: ViewDeckAgentPromptConfiguration
    @Published var copied = false

    init(configuration: ViewDeckAgentPromptConfiguration) {
        self.configuration = configuration
    }

    var prompt: String { ViewDeckAgentPromptBuilder.prompt(for: configuration) }

    func copyPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copied = false
        }
    }
}

final class ViewDeckAgentPromptWindowController: NSWindowController {
    init(configuration: ViewDeckAgentPromptConfiguration) {
        let model = ViewDeckAgentPromptModel(configuration: configuration)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_150, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Create ViewDeck Agent Prompt"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = DeckTheme.panel
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = CGSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ViewDeckAgentPromptView(model: model))
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }
}

private struct ViewDeckAgentPromptView: View {
    @ObservedObject var model: ViewDeckAgentPromptModel

    private let accent = Color(red: 184 / 255, green: 238 / 255, blue: 85 / 255)
    private let text = Color(red: 240 / 255, green: 244 / 255, blue: 247 / 255)
    private let secondary = Color(red: 170 / 255, green: 180 / 255, blue: 190 / 255)
    private let muted = Color(red: 112 / 255, green: 123 / 255, blue: 135 / 255)
    private let panel = Color(red: 14 / 255, green: 19 / 255, blue: 25 / 255)
    private let card = Color(red: 21 / 255, green: 27 / 255, blue: 35 / 255)
    private let field = Color(red: 10 / 255, green: 14 / 255, blue: 19 / 255)
    private let line = Color.white.opacity(0.09)
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            HSplitView {
                configurationPane
                    .frame(minWidth: 430, idealWidth: 500)
                promptPane
                    .frame(minWidth: 390, idealWidth: 600)
            }
        }
        .background(panel)
        .tint(accent)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.28)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Create agent prompt")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(text)
                Text("\(model.configuration.deviceName) · \(model.configuration.orientation.rawValue.capitalized)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(muted)
            }
            Spacer()
            Text("VIEWDECK QA")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(accent)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(accent.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(accent.opacity(0.24)))
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .background(Color.white.opacity(0.015))
        .overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 1) }
    }

    private var configurationPane: some View {
        ScrollView {
            VStack(spacing: 16) {
                taskSection
                sourceSection
                deviceSection
                readinessSection
                networkSection
                artifactSection
                policySection
            }
            .padding(20)
        }
        .scrollIndicators(.visible)
        .background(panel)
    }

    private var taskSection: some View {
        section("TASK") {
            VStack(spacing: 10) {
                menuRow("Workflow", selection: $model.configuration.workflow, values: ViewDeckAgentWorkflow.allCases)
                editorTextArea("What should the agent accomplish?", text: $model.configuration.objective, height: 92)
                editorTextField("ViewDeck executable path (optional)", text: $model.configuration.executablePath)
            }
        }
    }

    private var sourceSection: some View {
        section("SOURCE") {
            VStack(spacing: 10) {
                menuRow("Source type", selection: $model.configuration.sourceKind, values: ViewDeckAgentSourceKind.allCases)
                editorTextField(sourcePlaceholder, text: $model.configuration.sourceValue)
                if model.configuration.sourceKind == .project {
                    menuRow("Launch with", selection: $model.configuration.projectLaunch, values: ViewDeckAgentProjectLaunch.allCases)
                    if model.configuration.projectLaunch == .npmScript {
                        editorTextField("NPM script", text: $model.configuration.npmScript)
                    } else {
                        editorTextField("Custom server command", text: $model.configuration.customCommand)
                    }
                }
                editorTextField("Route (optional, e.g. /play)", text: $model.configuration.route)
            }
        }
    }

    private var deviceSection: some View {
        section("DEVICE & LAYOUT") {
            VStack(spacing: 10) {
                readOnlyRow("Device", value: model.configuration.deviceName)
                readOnlyRow("CLI ID", value: model.configuration.deviceID)
                menuRow("Orientation", selection: $model.configuration.orientation, values: ViewDeckAgentOrientation.allCases)
                Divider().overlay(line)
                toggle("Show safe-area guide", isOn: $model.configuration.showSafeArea)
                toggle("Apply safe area to page", isOn: $model.configuration.applySafeArea)
                toggle("Show CLI preview", isOn: $model.configuration.showPreview)
                if !model.configuration.showPreview {
                    readOnlyRow("Audio mode", value: "verify-silent (required)")
                }
                Divider().overlay(line)
                layerEditor("Header layer", kind: .header, layer: $model.configuration.header)
                layerEditor("Footer layer", kind: .footer, layer: $model.configuration.footer)
                layerEditor("Left landscape layer", kind: .left, layer: $model.configuration.left)
                layerEditor("Right landscape layer", kind: .right, layer: $model.configuration.right)
            }
        }
    }

    private var readinessSection: some View {
        section("READINESS") {
            VStack(spacing: 10) {
                editorTextField("Wait for CSS selector", text: $model.configuration.waitSelector)
                editorTextField("Wait for JavaScript expression", text: $model.configuration.waitJavaScript)
                editorTextArea("Prepare JavaScript", text: $model.configuration.prepareJavaScript, height: 64)
                LazyVGrid(columns: columns, spacing: 10) {
                    metric("Settle delay (seconds)", value: $model.configuration.delay)
                    metric("Timeout (seconds)", value: $model.configuration.timeout)
                }
            }
        }
    }

    private var networkSection: some View {
        section("NETWORK") {
            VStack(spacing: 10) {
                toggle("Enable deterministic shaping", isOn: $model.configuration.networkEnabled)
                if model.configuration.networkEnabled {
                    LazyVGrid(columns: columns, spacing: 10) {
                        metric("Round-trip latency (ms)", value: $model.configuration.networkRTT)
                        metric("Jitter (ms)", value: $model.configuration.networkJitter)
                        metric("Download (kbps)", value: $model.configuration.networkDown)
                        metric("Upload (kbps)", value: $model.configuration.networkUp)
                        metric("Seed", value: $model.configuration.networkSeed)
                    }
                    toggle("Offline", isOn: $model.configuration.networkOffline)
                }
            }
        }
    }

    private var artifactSection: some View {
        section("ARTIFACTS & REPLAY") {
            VStack(spacing: 10) {
                if model.configuration.workflow == .qaScenario {
                    editorTextField("Scenario name", text: $model.configuration.scenarioName)
                    editorTextField("Scenario output", text: $model.configuration.scenarioOutput)
                    editorTextField("Checkpoint directory", text: $model.configuration.checkpointDirectory)
                    editorTextField("Replay speed (smart, max, or factor)", text: $model.configuration.replaySpeed)
                } else if model.configuration.workflow != .inspect {
                    if model.configuration.workflow == .record {
                        editorTextField("Main MP4 output", text: $model.configuration.recordingOutput)
                    } else {
                        editorTextField("Main PNG output", text: $model.configuration.captureOutput)
                    }
                }
                editorTextField("Final screenshot (optional)", text: $model.configuration.screenshotOutput)
                editorTextField("Video output (optional)", text: $model.configuration.videoOutput)
                editorTextField("JSON report", text: $model.configuration.reportOutput)
                LazyVGrid(columns: columns, spacing: 10) {
                    metric("Screenshot scale", value: $model.configuration.captureScale)
                    metric("Video scale", value: $model.configuration.videoScale)
                    metric("Duration (seconds)", value: $model.configuration.duration)
                    metric("FPS", value: $model.configuration.fps)
                }
            }
        }
    }

    private var policySection: some View {
        section("POLICY & ADVANCED") {
            VStack(spacing: 10) {
                toggle("Overwrite outputs", isOn: $model.configuration.overwrite)
                toggle("Fail on page error", isOn: $model.configuration.failOnPageError)
                toggle("Fail on layout issues", isOn: $model.configuration.failOnIssues)
                toggle("Print JSON", isOn: $model.configuration.json)
                editorTextField("Additional CLI arguments (each command)", text: $model.configuration.additionalCLIArguments)
                editorTextArea("Additional agent instructions", text: $model.configuration.additionalInstructions, height: 76)
            }
        }
    }

    private var promptPane: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GENERATED PROMPT")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(muted)
                    Text("Updates as you configure the run")
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 66)
            .overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 1) }

            ScrollView {
                Text(model.prompt)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(text.opacity(0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
            .scrollIndicators(.visible)
            .background(field.opacity(0.72))

            HStack(spacing: 10) {
                Text(model.copied ? "Copied to clipboard" : "Ready to paste into your LLM agent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.copied ? accent : muted)
                Spacer()
                Button(action: model.copyPrompt) {
                    Label(model.copied ? "Copied" : "Copy prompt", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(AgentPromptPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Copy the complete ViewDeck QA prompt")
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            .background(Color.white.opacity(0.018))
            .overlay(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
        }
        .background(Color(red: 11 / 255, green: 15 / 255, blue: 20 / 255))
    }

    private var sourcePlaceholder: String {
        switch model.configuration.sourceKind {
        case .url: "https://example.com"
        case .project: "/absolute/path/to/project"
        case .htmlFile: "/absolute/path/to/index.html"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(muted)
                .padding(.leading, 2)
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(line))
        }
    }

    private func editorTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(self.text)
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(field, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(line))
    }

    private func editorTextArea(_ placeholder: String, text: Binding<String>, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11.5))
                    .foregroundStyle(muted)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
            }
            TextEditor(text: text)
                .scrollContentBackground(.hidden)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(self.text)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
        }
        .frame(height: height)
        .background(field, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(line))
    }

    private func metric(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(secondary)
            TextField("", text: value)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(text)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(field, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(line))
        }
    }

    private func menuRow<Value: Hashable & Identifiable & RawRepresentable>(
        _ title: String,
        selection: Binding<Value>,
        values: [Value]
    ) -> some View where Value.RawValue == String {
        HStack {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(secondary)
            Spacer()
            Picker("", selection: selection) {
                ForEach(values) { value in Text(value.rawValue).tag(value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 220)
        }
    }

    private func readOnlyRow(_ title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(text)
    }

    private func layerEditor(
        _ title: String,
        kind: HTMLLayerKind,
        layer: Binding<ViewDeckAgentLayerConfiguration>
    ) -> some View {
        VStack(spacing: 8) {
            toggle(title, isOn: layer.isSelected)
            if layer.wrappedValue.isSelected {
                editorTextField("Absolute HTML file path", text: layer.path)
                HStack(spacing: 10) {
                    TextField("Layer name", text: layer.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(text)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(field, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(line))
                    TextField(kind.reservedDimension.capitalized, text: layer.extent)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(text)
                        .padding(.horizontal, 10)
                        .frame(width: 90, height: 34)
                        .background(field, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(line))
                }
            }
        }
    }
}

private struct AgentPromptPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color(red: 21 / 255, green: 32 / 255, blue: 6 / 255))
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Color(red: 184 / 255, green: 238 / 255, blue: 85 / 255), in: RoundedRectangle(cornerRadius: 9))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
