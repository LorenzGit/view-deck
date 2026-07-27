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
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                iconButton(
                    "arrow.triangle.2.circlepath",
                    help: "Rotate device",
                    action: model.rotate
                )
                screenshotButton
                iconButton(
                    "wrench.and.screwdriver",
                    help: "Open Web Inspector",
                    action: model.openDeveloperTools
                )
                Spacer(minLength: 0)
            }

            HStack(spacing: 5) {
                qaControls
                Spacer(minLength: 0)
                recordVideoToggle
            }
        }
        .padding(5)
        .frame(height: 80)
        .background(ToolbarPalette.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ToolbarPalette.line))
        .environment(\.colorScheme, .dark)
    }

    private var recordVideoToggle: some View {
        VStack(spacing: 0) {
            Text("Record Video")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(ToolbarPalette.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
            Toggle("", isOn: $model.recordQAVideo)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Record Video")
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(model.isQARecording || model.isQAReplaying)
        .help("Save an MP4 alongside the recorded QA scenario")
    }

    private var screenshotButton: some View {
        Button(action: model.captureScreenshot) {
            Group {
                if model.isCapturingScreenshot {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ToolbarPalette.accent)
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ToolbarPalette.accent)
                }
            }
            .frame(width: 32, height: 32)
            .background(ToolbarPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ToolbarPalette.accent.opacity(0.28)))
        }
        .buttonStyle(DeckToolbarButtonStyle())
        .disabled(model.isCapturingScreenshot)
        .help(model.isCapturingScreenshot ? "Capturing device…" : "Capture and mark up this device")
        .accessibilityLabel(model.isCapturingScreenshot ? "Capturing device" : "Capture and mark up device")
    }

    private var qaControls: some View {
        HStack(spacing: 2) {
            Button(action: model.toggleQARecording) {
                Image(systemName: model.isQARecording ? "stop.fill" : "record.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.isQARecording ? Color.white : Color.red)
                    .frame(width: 29, height: 28)
                    .background(
                        (model.isQARecording ? Color.red : Color.red.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
            }
            .buttonStyle(DeckToolbarButtonStyle())
            .disabled(model.isQAReplaying)
            .help(recordButtonHelp)
            .accessibilityLabel(model.isQARecording ? "Stop QA recording" : "Start QA recording")

            Button(action: model.addQACheckpoint) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 11, weight: .semibold))
                    if model.qaCheckpointCount > 0 {
                        Text("\(model.qaCheckpointCount)")
                            .font(.system(size: 7, weight: .bold))
                            .padding(2)
                            .background(ToolbarPalette.accent, in: Circle())
                            .foregroundStyle(Color.black)
                            .offset(x: 5, y: -5)
                    }
                }
                .foregroundStyle(model.isQARecording ? ToolbarPalette.accent : ToolbarPalette.muted)
                .frame(width: 29, height: 28)
            }
            .buttonStyle(DeckToolbarButtonStyle())
            .disabled(!model.isQARecording)
            .help("Capture a named QA checkpoint screenshot")
            .accessibilityLabel("Add QA checkpoint")

            Button(action: model.isQAReplaying ? model.stopQAReplay : model.replayQAScenario) {
                Image(systemName: model.isQAReplaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.isQAReplaying ? Color.white : ToolbarPalette.secondary)
                .frame(width: 29, height: 28)
                .background(
                    model.isQAReplaying ? Color.red : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
            }
            .buttonStyle(DeckToolbarButtonStyle())
            .disabled(model.isQARecording)
            .help(model.isQAReplaying ? "Stop QA replay" : "Replay a .viewdeck.json scenario")
            .accessibilityLabel(model.isQAReplaying ? "Stop QA replay" : "Replay QA scenario")
        }
        .padding(.horizontal, 2)
        .frame(height: 32)
        .background(Color.white.opacity(0.028), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ToolbarPalette.line))
    }

    private var recordButtonHelp: String {
        if model.isQARecording {
            return "Stop and save QA recording"
        }
        return model.recordQAVideo
            ? "Record input, checkpoints, and video"
            : "Record input and checkpoints"
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ToolbarPalette.secondary)
                .frame(width: 32, height: 32)
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
