import SwiftUI

final class DeckToolbarModel: ObservableObject {
    @Published var width = "440"
    @Published var height = "956"
    @Published var dpr = 3.0
    @Published var address = ""
    @Published var isCapturingScreenshot = false
    @Published var isQARecording = false
    @Published var isQAReplaying = false
    @Published var recordQAVideo = false
    @Published var qaCheckpointCount = 0

    var commitViewport: (Double, Double) -> Void = { _, _ in }
    var changeDPR: (Double) -> Void = { _ in }
    var rotate: () -> Void = {}
    var captureScreenshot: () -> Void = {}
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
    }
}

struct DeckQuickActionsView: View {
    @ObservedObject var model: DeckToolbarModel

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text("TEST TOOLS")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(ToolbarPalette.muted)
                Spacer(minLength: 0)
                activityStatus
            }

            HStack(spacing: 5) {
                actionButton(
                    "arrow.triangle.2.circlepath",
                    title: "Rotate",
                    help: "Rotate device",
                    action: model.rotate
                )
                screenshotButton
                actionButton(
                    "wrench.and.screwdriver",
                    title: "Inspect",
                    help: "Open Web Inspector",
                    action: model.openDeveloperTools
                )
            }

            Rectangle()
                .fill(ToolbarPalette.line)
                .frame(height: 1)

            recordVideoToggle
            actionRecordingButton
            scenarioControls
        }
        .padding(9)
        .frame(height: 228)
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
        if model.isQARecording { return "RECORDING ACTIONS" }
        if model.isQAReplaying { return "REPLAYING" }
        return "READY"
    }

    private var activityColor: Color {
        if model.isQARecording { return .red }
        if model.isQAReplaying { return ToolbarPalette.accent }
        return ToolbarPalette.secondary
    }

    private var recordVideoToggle: some View {
        HStack(spacing: 8) {
            Image(systemName: model.recordQAVideo ? "video.fill" : "video")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.recordQAVideo ? ToolbarPalette.accent : ToolbarPalette.muted)
                .frame(width: 22, height: 22)
                .background(
                    (model.recordQAVideo ? ToolbarPalette.accent.opacity(0.12) : Color.white.opacity(0.025)),
                    in: RoundedRectangle(cornerRadius: 6)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Video capture")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(ToolbarPalette.text)
                    .lineLimit(1)
                Text("MP4 · 30 FPS")
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(ToolbarPalette.muted)
                    .lineLimit(1)
            }
            .accessibilityHidden(true)

            Spacer(minLength: 2)

            Toggle("", isOn: $model.recordQAVideo)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Include video capture")
        }
        .padding(.horizontal, 7)
        .frame(height: 38)
        .background(
            model.recordQAVideo ? ToolbarPalette.accent.opacity(0.055) : Color.white.opacity(0.018),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(model.recordQAVideo ? ToolbarPalette.accent.opacity(0.22) : ToolbarPalette.line)
        )
        .disabled(model.isQARecording || model.isQAReplaying)
        .opacity(model.isQARecording || model.isQAReplaying ? 0.68 : 1)
        .help("Include a performance-optimized 30 FPS MP4 with the actions recording")
    }

    private var screenshotButton: some View {
        Button(action: model.captureScreenshot) {
            VStack(spacing: 2) {
                if model.isCapturingScreenshot {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(ToolbarPalette.secondary)
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text("Markup")
                    .font(.system(size: 8.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(ToolbarPalette.secondary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ToolbarPalette.line))
        }
        .buttonStyle(DeckToolbarButtonStyle())
        .disabled(model.isCapturingScreenshot)
        .help(model.isCapturingScreenshot ? "Capturing device…" : "Capture and mark up this device")
        .accessibilityLabel(model.isCapturingScreenshot ? "Capturing device" : "Capture and mark up device")
    }

    private var actionRecordingButton: some View {
        Button(action: model.toggleQARecording) {
            HStack(spacing: 7) {
                Image(systemName: model.isQARecording ? "stop.fill" : "cursorarrow.click.2")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 0) {
                    Text(model.isQARecording ? "Stop & save" : "Record actions")
                        .font(.system(size: 9, weight: .bold))
                        .lineLimit(1)
                    Text(model.isQARecording ? "Finish actions JSON" : "Clicks, keys & forms")
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(model.isQARecording ? Color.white.opacity(0.78) : Color.red.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                Text("JSON")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(
                        model.isQARecording ? Color.white.opacity(0.16) : Color.red.opacity(0.10),
                        in: Capsule()
                    )
            }
            .foregroundStyle(model.isQARecording ? Color.white : Color.red)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                model.isQARecording ? Color.red : Color.red.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(model.isQARecording ? Color.red : Color.red.opacity(0.22))
            )
        }
        .buttonStyle(DeckToolbarButtonStyle())
        .disabled(model.isQAReplaying)
        .help(recordButtonHelp)
        .accessibilityLabel(
            model.isQARecording ? "Stop and save actions JSON" : "Record actions to JSON"
        )
    }

    private var scenarioControls: some View {
        HStack(spacing: 5) {
            Button(action: model.addQACheckpoint) {
                HStack(spacing: 4) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        if model.qaCheckpointCount > 0 {
                            Text("\(model.qaCheckpointCount)")
                                .font(.system(size: 6.5, weight: .bold))
                                .padding(2)
                                .background(ToolbarPalette.accent, in: Circle())
                                .foregroundStyle(Color.black)
                                .offset(x: 5, y: -5)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Screenshot")
                            .font(.system(size: 8, weight: .semibold))
                            .lineLimit(1)
                        Text("Local PNG")
                            .font(.system(size: 6.8, weight: .medium))
                            .foregroundStyle(
                                model.isQARecording
                                    ? ToolbarPalette.accent.opacity(0.72)
                                    : ToolbarPalette.muted.opacity(0.72)
                            )
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(model.isQARecording ? ToolbarPalette.accent : ToolbarPalette.muted)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Color.white.opacity(0.022), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ToolbarPalette.line))
            }
            .buttonStyle(DeckToolbarButtonStyle())
            .disabled(!model.isQARecording)
            .help("Save a checkpoint PNG beside the actions JSON")
            .accessibilityLabel("Save checkpoint screenshot locally as PNG")

            Button(action: model.isQAReplaying ? model.stopQAReplay : model.replayQAScenario) {
                HStack(spacing: 4) {
                    Image(systemName: model.isQAReplaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(model.isQAReplaying ? "Stop" : "Replay")
                        .font(.system(size: 8, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(model.isQAReplaying ? Color.black : ToolbarPalette.secondary)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(
                    model.isQAReplaying ? ToolbarPalette.accent : Color.white.opacity(0.022),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                    model.isQAReplaying ? ToolbarPalette.accent : ToolbarPalette.line
                ))
            }
            .buttonStyle(DeckToolbarButtonStyle())
            .disabled(model.isQARecording)
            .help(model.isQAReplaying ? "Stop QA replay" : "Replay a .viewdeck.json scenario")
            .accessibilityLabel(model.isQAReplaying ? "Stop QA replay" : "Replay QA scenario")
        }
    }

    private var recordButtonHelp: String {
        if model.isQARecording {
            return "Stop and save the recorded actions JSON"
        }
        return model.recordQAVideo
            ? "Record actions to JSON and include an MP4 video"
            : "Record actions to JSON"
    }

    private func actionButton(
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
            .frame(maxWidth: .infinity, minHeight: 38)
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
