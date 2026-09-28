import AppKit

struct DetachedPlayerWindowLayout {
    static let padding: CGFloat = 28

    static func initialContentSize(logicalSize: CGSize, maximumSize: CGSize) -> CGSize {
        guard logicalSize.width > 0, logicalSize.height > 0 else {
            return CGSize(width: 360, height: 640)
        }
        let totalPadding = padding * 2
        let scale = min(
            1,
            max(0.12, (maximumSize.width - totalPadding) / logicalSize.width),
            max(0.12, (maximumSize.height - totalPadding) / logicalSize.height)
        )
        return CGSize(
            width: logicalSize.width * scale + totalPadding,
            height: logicalSize.height * scale + totalPadding
        )
    }
}

final class DetachedPlayerWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "ViewDeck Detached Player"
    private let canvas: PreviewCanvasView
    var requestReattach: () -> Void = {}

    init(canvas: PreviewCanvasView) {
        self.canvas = canvas
        let visibleSize = NSScreen.main?.visibleFrame.insetBy(dx: 60, dy: 60).size
            ?? CGSize(width: 900, height: 900)
        let contentSize = DetachedPlayerWindowLayout.initialContentSize(
            logicalSize: canvas.preview.logicalSize,
            maximumSize: visibleSize
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ViewDeck Player"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.sharingType = .readWrite
        window.isExcludedFromWindowsMenu = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.minSize = CGSize(width: 220, height: 300)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.delegate = self

        canvas.presentation = .detached
        canvas.translatesAutoresizingMaskIntoConstraints = true
        canvas.autoresizingMask = [.width, .height]
        canvas.frame = CGRect(origin: .zero, size: contentSize)
        window.contentView = canvas

        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    required init?(coder: NSCoder) { nil }

    func relinquishCanvas() {
        window?.delegate = nil
        canvas.removeFromSuperview()
        window?.contentView = nil
        dismiss()
    }

    func dismiss() {
        window?.delegate = nil
        window?.orderOut(nil)
        close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        DispatchQueue.main.async { [requestReattach] in requestReattach() }
        return false
    }
}
