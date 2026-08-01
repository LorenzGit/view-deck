import SwiftUI

enum DeckVideoCaptureState: Equatable {
    case idle
    case recording
    case saving
}

final class DeckToolbarModel: ObservableObject {
    @Published var width = "440"
    @Published var height = "956"
    @Published var dpr = 3.0
    @Published var address = ""
    @Published var isCapturingScreenshot = false
    @Published var isQARecording = false
    @Published var isQARecordingReady = false
    @Published var isQAReplaying = false
    @Published var videoCaptureState = DeckVideoCaptureState.idle
    @Published var qaCheckpointCount = 0
    @Published var isSidebarCollapsed = false

    var commitViewport: (Double, Double) -> Void = { _, _ in }
    var changeDPR: (Double) -> Void = { _ in }
    var toggleSidebar: () -> Void = {}
    var rotate: () -> Void = {}
    var captureScreenshot: () -> Void = {}
    var toggleVideoRecording: () -> Void = {}
    var toggleQARecording: () -> Void = {}
    var addQACheckpoint: () -> Void = {}
    var replayQAScenario: () -> Void = {}
    var stopQAReplay: () -> Void = {}
    var back: () -> Void = {}
    var forward: () -> Void = {}
    var reload: () -> Void = {}
    var openDeveloperTools: () -> Void = {}
    var load: (String) -> Void = { _ in }
}

private enum ToolbarPalette {
    static let accent = Color(red: 184 / 255, green: 238 / 255, blue: 85 / 255)
    static let text = Color(red: 235 / 255, green: 240 / 255, blue: 244 / 255)
    static let secondary = Color(red: 166 / 255, green: 176 / 255, blue: 186 / 255)
    static let muted = Color(red: 111 / 255, green: 122 / 255, blue: 134 / 255)
    static let line = Color.white.opacity(0.085)
    static let field = Color(red: 11 / 255, green: 15 / 255, blue: 20 / 255)
    static let background = Color(red: 15 / 255, green: 20 / 255, blue: 27 / 255)
}

struct DeckToolbarView: View {
    @ObservedObject var model: DeckToolbarModel

    var body: some View {
        toolbarRow
            .environment(\.colorScheme, .dark)
    }

    private var toolbarRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                browserIcon(
                    "sidebar.left",
                    help: model.isSidebarCollapsed ? "Show device library" : "Hide device library",
                    action: model.toggleSidebar
                )
                Rectangle()
                    .fill(ToolbarPalette.line)
                    .frame(width: 1, height: 16)
                browserIcon("chevron.left", help: "Back", action: model.back)
                browserIcon("chevron.right", help: "Forward", action: model.forward)
                browserIcon("arrow.clockwise", help: "Reload", action: model.reload)
            }
            .padding(.horizontal, 2)
            .frame(height: 32)
            .background(Color.white.opacity(0.028), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(ToolbarPalette.line))

            HStack(spacing: 8) {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(ToolbarPalette.muted)
                TextField("localhost:5173", text: $model.address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ToolbarPalette.text)
                    .onSubmit { model.load(model.address) }
                    .help("Enter the web address to load in the preview")
                Circle()
                    .fill(ToolbarPalette.accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: ToolbarPalette.accent.opacity(0.5), radius: 4)
                    .help("Address ready")
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(ToolbarPalette.field, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(ToolbarPalette.line))
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(ToolbarPalette.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ToolbarPalette.line).frame(height: 1) }
    }

    private func browserIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ToolbarPalette.muted)
                .frame(width: 29, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(DeckToolbarButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

struct DeckQuickActionsView: View {
    @ObservedObject var model: DeckToolbarModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("TEST TOOLS")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(ToolbarPalette.muted)
                Spacer(minLength: 0)
                activityStatus
            }

            HStack(spacing: 5) {
                utilityButton(
                    "arrow.triangle.2.circlepath",
                    title: "Rotate",
                    help: "Rotate device",
                    action: model.rotate
                )
                utilityButton(
                    "wrench.and.screwdriver",
                    title: "Inspect",
                    help: "Open Web Inspector",
                    action: model.openDeveloperTools
                )
            }

            sectionLabel("CAPTURE")
            captureControls
            sectionLabel("TEST SCENARIOS")
            scenarioControls
        }
        .padding(9)
        .frame(height: 252)
        .background(ToolbarPalette.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ToolbarPalette.line))
        .environment(\.colorScheme, .dark)
    }

    private var activityStatus: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(activityColor)
                .frame(width: 5, height: 5)
                .shadow(color: activityColor.opacity(0.5), radius: 3)
            Text(activityTitle)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(activityColor)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(activityColor.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(activityColor.opacity(0.18)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activityTitle)
    }

    private var activityTitle: String {
        if model.videoCaptureState == .recording { return "CAPTURING VIDEO" }
        if model.videoCaptureState == .saving { return "SAVING VIDEO" }
        if model.isQARecording {
            return model.isQARecordingReady ? "RECORDING TEST" : "PREPARING TEST"
        }
        if model.isQAReplaying { return "REPLAYING TEST" }
        return "READY"
    }

    private var activityColor: Color {
        if model.videoCaptureState == .recording || model.isQARecordingReady { return .red }
        if model.isQAReplaying { return ToolbarPalette.accent }
        return ToolbarPalette.secondary
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 7.5, weight: .bold))
                .tracking(0.55)
                .foregroundStyle(ToolbarPalette.muted)
            Rectangle()
                .fill(ToolbarPalette.line)
                .frame(height: 1)
        }
    }

    private var captureControls: some View {
        HStack(spacing: 5) {
            labeledButton(
                symbol: model.isCapturingScreenshot ? "hourglass" : "camera.viewfinder",
                title: "Screenshot",
                detail: model.isCapturingScreenshot ? "Capturing…" : "Capture + edit",
                help: model.isCapturingScreenshot ? "Capturing device…" : "Capture and edit this device",
                disabled: captureControlsDisabled || model.isCapturingScreenshot,
                action: model.captureScreenshot
            )
            videoRecordingButton
        }
    }

    @ViewBuilder
    private var videoRecordingButton: some View {
        switch model.videoCaptureState {
        case .idle:
            labeledButton(
                symbol: "video.fill",
                title: "Record video",
                detail: "MP4 · 30 FPS",
                help: "Record the current device preview as an MP4",
                disabled: model.isCapturingScreenshot || model.isQARecording || model.isQAReplaying,
                action: model.toggleVideoRecording
            )
        case .recording:
            labeledButton(
                symbol: "stop.fill",
                title: "Stop video",
                detail: "Finish MP4",
                help: "Stop and save the video recording",
                foreground: .red,
                background: Color.red.opacity(0.08),
                border: Color.red.opacity(0.28),
                action: model.toggleVideoRecording
            )
        case .saving:
            labeledButton(
                symbol: "hourglass",
                title: "Saving video",
                detail: "Finishing MP4",
                help: "The video recording is being saved",
                disabled: true,
                action: {}
            )
        }
    }

    private var scenarioControls: some View {
        HStack(spacing: 5) {
            labeledButton(
                symbol: model.isQARecording ? "stop.fill" : "record.circle",
                title: recordButtonTitle,
                detail: recordButtonDetail,
                help: recordButtonHelp,
                foreground: model.isQARecordingReady ? .red : ToolbarPalette.secondary,
                background: model.isQARecordingReady ? Color.red.opacity(0.08) : Color.white.opacity(0.022),
                border: model.isQARecordingReady ? Color.red.opacity(0.28) : ToolbarPalette.line,
                disabled: model.isQAReplaying || model.videoCaptureState != .idle,
                action: model.toggleQARecording
            )
            scenarioSecondaryButton
        }
    }

    @ViewBuilder
    private var scenarioSecondaryButton: some View {
        if model.isQARecording {
            labeledButton(
                symbol: "camera.fill",
                title: "Add checkpoint",
                detail: checkpointDetail,
                help: "Capture the current state as a checkpoint PNG",
                foreground: ToolbarPalette.accent,
                disabled: !model.isQARecordingReady,
                action: model.addQACheckpoint
            )
        } else if model.isQAReplaying {
            labeledButton(
                symbol: "stop.fill",
                title: "Stop replay",
                detail: "Cancel playback",
                help: "Stop the test replay",
                foreground: Color.black,
                background: ToolbarPalette.accent,
                border: ToolbarPalette.accent,
                action: model.stopQAReplay
            )
        } else {
            labeledButton(
                symbol: "play.fill",
                title: "Replay test",
                detail: "Choose scenario",
                help: "Replay a .viewdeck.json test scenario",
                disabled: model.videoCaptureState != .idle,
                action: model.replayQAScenario
            )
        }
    }

    private var captureControlsDisabled: Bool {
        model.videoCaptureState != .idle || model.isQARecording || model.isQAReplaying
    }

    private var checkpointDetail: String {
        guard model.isQARecordingReady else { return "Preparing…" }
        return model.qaCheckpointCount == 0
            ? "Capture state"
            : "\(model.qaCheckpointCount) saved"
    }

    private var recordButtonTitle: String {
        guard model.isQARecording else { return "Record test" }
        return model.isQARecordingReady ? "Stop & save" : "Cancel test"
    }

    private var recordButtonDetail: String {
        guard model.isQARecording else { return "Actions + checkpoints" }
        return model.isQARecordingReady ? "Finish scenario" : "Reloading page…"
    }

    private var recordButtonHelp: String {
        guard model.isQARecording else {
            return "Record actions and checkpoints to a test scenario"
        }
        return model.isQARecordingReady
            ? "Stop and save the test scenario"
            : "Cancel the pending test recording"
    }

    private func labeledButton(
        symbol: String,
        title: String,
        detail: String,
        help: String,
        foreground: Color = ToolbarPalette.secondary,
        background: Color = Color.white.opacity(0.022),
        border: Color = ToolbarPalette.line,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 6.7, weight: .medium))
                        .foregroundStyle(foreground.opacity(0.68))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border))
        }
        .buttonStyle(DeckToolbarButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.62 : 1)
        .help(help)
        .accessibilityLabel("\(title). \(detail)")
    }

    private func utilityButton(
        _ symbol: String,
        title: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 8.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(ToolbarPalette.secondary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ToolbarPalette.line))
        }
        .buttonStyle(DeckToolbarButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct DeckToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DeckToolbarButtonBody(configuration: configuration)
    }
}

private struct DeckToolbarButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .brightness(configuration.isPressed ? -0.08 : hovering ? 0.07 : 0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}
