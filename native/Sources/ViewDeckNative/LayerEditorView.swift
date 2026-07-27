import SwiftUI

final class LayerEditorModel: ObservableObject {
    @Published var name: String
    @Published var html: String
    @Published var reservedHeight: String

    init(name: String, html: String, reservedHeight: CGFloat) {
        self.name = name
        self.html = html
        self.reservedHeight = reservedHeight.formatted()
    }

    var parsedHeight: CGFloat {
        max(20, min(600, Double(reservedHeight) ?? 48))
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum LayerEditorPalette {
    static let accent = Color(red: 184 / 255, green: 238 / 255, blue: 85 / 255)
    static let accentInk = Color(red: 21 / 255, green: 32 / 255, blue: 6 / 255)
    static let text = Color(red: 239 / 255, green: 243 / 255, blue: 246 / 255)
    static let secondary = Color(red: 173 / 255, green: 183 / 255, blue: 193 / 255)
    static let muted = Color(red: 119 / 255, green: 130 / 255, blue: 142 / 255)
    static let line = Color.white.opacity(0.10)
    static let panel = Color(red: 15 / 255, green: 19 / 255, blue: 25 / 255)
    static let raised = Color(red: 20 / 255, green: 26 / 255, blue: 34 / 255)
    static let field = Color(red: 10 / 255, green: 14 / 255, blue: 19 / 255)
}

struct LayerEditorView: View {
    @ObservedObject var model: LayerEditorModel
    let kind: HTMLLayerKind
    let editingExisting: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LayerEditorPalette.line)

            VStack(alignment: .leading, spacing: 18) {
                metadata

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("HTML SOURCE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(LayerEditorPalette.muted)
                        Spacer()
                        Text("Runs in an isolated WKWebView")
                            .font(.system(size: 10))
                            .foregroundStyle(LayerEditorPalette.muted)
                    }

                    TextEditor(text: $model.html)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LayerEditorPalette.text)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(LayerEditorPalette.field, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(LayerEditorPalette.line))
                        .accessibilityLabel("Layer HTML source")
                }
                .frame(maxHeight: .infinity)
            }
            .padding(22)

            Divider().overlay(LayerEditorPalette.line)
            footer
        }
        .frame(minWidth: 700, minHeight: 580)
        .background(LayerEditorPalette.panel)
        .environment(\.colorScheme, .dark)
        .tint(LayerEditorPalette.accent)
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: kind == .header ? "rectangle.topthird.inset.filled" : "rectangle.bottomthird.inset.filled")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LayerEditorPalette.accent)
                .frame(width: 38, height: 38)
                .background(LayerEditorPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(LayerEditorPalette.accent.opacity(0.24)))

            VStack(alignment: .leading, spacing: 3) {
                Text("\(editingExisting ? "Edit" : "Create") \(kind.rawValue) layer")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LayerEditorPalette.text)
                Text("Reusable HTML rendered outside the page viewport")
                    .font(.system(size: 11))
                    .foregroundStyle(LayerEditorPalette.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 74)
        .background(LayerEditorPalette.raised.opacity(0.55))
    }

    private var metadata: some View {
        HStack(alignment: .top, spacing: 14) {
            editorField("LAYER NAME", text: $model.name, prompt: "Example: Product toolbar")
                .frame(maxWidth: .infinity)
            editorField("RESERVED HEIGHT", text: $model.reservedHeight, prompt: "48")
                .frame(width: 156)
        }
    }

    private func editorField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(LayerEditorPalette.muted)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LayerEditorPalette.text)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(LayerEditorPalette.field, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(LayerEditorPalette.line))
                .help("Edit \(title.lowercased())")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.canSave ? "⌘S to save" : "Name and HTML are required")
                .font(.system(size: 10.5))
                .foregroundStyle(LayerEditorPalette.muted)
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(LayerEditorSecondaryButtonStyle())
                .help("Close without saving this layer")
            Button(action: onSave) {
                Label("Save layer", systemImage: "checkmark")
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(LayerEditorPrimaryButtonStyle())
            .disabled(!model.canSave)
            .help("Save this reusable HTML layer")
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
        .background(LayerEditorPalette.raised.opacity(0.45))
    }
}

private struct LayerEditorSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(LayerEditorPalette.secondary)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(LayerEditorPalette.line))
    }
}

private struct LayerEditorPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(LayerEditorPalette.accentInk)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(LayerEditorPalette.accent.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 9))
    }
}
