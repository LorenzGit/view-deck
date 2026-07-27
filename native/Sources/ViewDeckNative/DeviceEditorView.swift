import SwiftUI

final class DeviceEditorModel: ObservableObject {
    private let seed: DeviceProfile

    @Published var name: String
    @Published var platform: String
    @Published var viewportWidth: String
    @Published var viewportHeight: String
    @Published var dpr: String
    @Published var shellTop: String
    @Published var shellRight: String
    @Published var shellBottom: String
    @Published var shellLeft: String
    @Published var cornerRadius: String
    @Published var safeTop: String
    @Published var safeRight: String
    @Published var safeBottom: String
    @Published var safeLeft: String
    @Published var sensorType: String
    @Published var sensorWidth: String
    @Published var sensorHeight: String
    @Published var sensorTop: String
    @Published var safariChrome: Bool
    @Published var homeIndicator: Bool

    init(profile: DeviceProfile) {
        seed = profile
        name = profile.name
        platform = profile.platform.rawValue
        viewportWidth = profile.viewport.width.formatted()
        viewportHeight = profile.viewport.height.formatted()
        dpr = profile.viewport.dpr.formatted()
        shellTop = profile.shell.top.formatted()
        shellRight = profile.shell.right.formatted()
        shellBottom = profile.shell.bottom.formatted()
        shellLeft = profile.shell.left.formatted()
        cornerRadius = profile.shell.radius.formatted()
        safeTop = profile.safeArea.top.formatted()
        safeRight = profile.safeArea.right.formatted()
        safeBottom = profile.safeArea.bottom.formatted()
        safeLeft = profile.safeArea.left.formatted()
        sensorType = profile.sensor.type.rawValue
        sensorWidth = profile.sensor.width.formatted()
        sensorHeight = profile.sensor.height.formatted()
        sensorTop = profile.sensor.top.formatted()
        safariChrome = profile.safariChrome
        homeIndicator = profile.homeIndicator
    }

    func makeProfile() -> DeviceProfile {
        var profile = seed
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom device" : name
        profile.platform = DevicePlatform(rawValue: platform) ?? .custom
        profile.viewport = Viewport(
            width: max(240, number(viewportWidth)),
            height: max(320, number(viewportHeight)),
            dpr: max(1, number(dpr))
        )
        profile.shell = DeviceShell(
            top: number(shellTop),
            right: number(shellRight),
            bottom: number(shellBottom),
            left: number(shellLeft),
            radius: number(cornerRadius)
        )
        profile.safeArea = EdgeInsets(
            top: number(safeTop),
            right: number(safeRight),
            bottom: number(safeBottom),
            left: number(safeLeft)
        )
        profile.sensor = DeviceSensor(
            type: SensorType(rawValue: sensorType) ?? .none,
            width: number(sensorWidth),
            height: number(sensorHeight),
            top: number(sensorTop)
        )
        profile.safariChrome = safariChrome
        profile.homeIndicator = homeIndicator
        profile.builtin = false
        return profile
    }

    private func number(_ value: String) -> CGFloat {
        CGFloat(Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }
}

struct DeviceEditorView: View {
    @ObservedObject var model: DeviceEditorModel
    let editing: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

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

            ScrollView {
                VStack(spacing: 16) {
                    section("IDENTITY") {
                        VStack(spacing: 10) {
                            editorTextField("Device name", text: $model.name)
                            menuRow("Platform", selection: $model.platform, values: DevicePlatform.allCases.map(\.rawValue))
                        }
                    }

                    section("VIEWPORT") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            metric("Width", value: $model.viewportWidth)
                            metric("Height", value: $model.viewportHeight)
                            metric("Pixel ratio", value: $model.dpr)
                        }
                    }

                    section("OUTER SHELL") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            metric("Top", value: $model.shellTop)
                            metric("Right", value: $model.shellRight)
                            metric("Bottom", value: $model.shellBottom)
                            metric("Left", value: $model.shellLeft)
                            metric("Corner radius", value: $model.cornerRadius)
                        }
                    }

                    section("SAFE AREA") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            metric("Top", value: $model.safeTop)
                            metric("Right", value: $model.safeRight)
                            metric("Bottom", value: $model.safeBottom)
                            metric("Left", value: $model.safeLeft)
                        }
                    }

                    section("SENSOR & SYSTEM UI") {
                        VStack(spacing: 10) {
                            menuRow("Sensor type", selection: $model.sensorType, values: SensorType.allCases.map(\.rawValue))
                            LazyVGrid(columns: columns, spacing: 10) {
                                metric("Sensor width", value: $model.sensorWidth)
                                metric("Sensor height", value: $model.sensorHeight)
                                metric("Sensor top", value: $model.sensorTop)
                            }
                            Divider().overlay(line)
                            Toggle("Safari browser chrome", isOn: $model.safariChrome)
                                .toggleStyle(.switch)
                                .help("Show the simulated iOS Safari bars for this device")
                            Toggle("Home indicator", isOn: $model.homeIndicator)
                                .toggleStyle(.switch)
                                .help("Show the iOS home indicator when Safari chrome is hidden")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(text)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.visible)

            footer
        }
        .frame(width: 590, height: 680)
        .background(panel)
        .tint(accent)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.28)))
            VStack(alignment: .leading, spacing: 3) {
                Text(editing ? "Edit device skin" : "Add device skin")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(text)
                Text("Define the viewport, shell, sensors, and safe-area geometry.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(muted)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .background(Color.white.opacity(0.015))
        .overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(EditorSecondaryButtonStyle())
                .help("Close without saving this device")
            Button(action: onSave) {
                Label("Save device", systemImage: "checkmark")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(EditorPrimaryButtonStyle())
            .help("Save this device to the device library")
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(Color.white.opacity(0.018))
        .overlay(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
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
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(self.text)
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(field, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(line))
            .help("Edit \(placeholder.lowercased())")
    }

    private func metric(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(secondary)
            TextField("0", text: value)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(text)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(field, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(line))
                .help("Edit \(label.lowercased())")
        }
    }

    private func menuRow(_ title: String, selection: Binding<String>, values: [String]) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(secondary)
            Spacer()
            Picker("", selection: selection) {
                ForEach(values, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 190)
            .help("Choose \(title.lowercased())")
        }
    }
}

private struct EditorPrimaryButtonStyle: ButtonStyle {
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

private struct EditorSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.72))
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.10)))
    }
}
