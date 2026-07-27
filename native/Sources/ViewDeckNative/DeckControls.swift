import AppKit

enum DeckTheme {
    static let window = NSColor(hex: 0x090c10)
    static let titlebar = NSColor(hex: 0x0c1015, alpha: 0.98)
    static let sidebar = NSColor(hex: 0x0e1218)
    static let panel = NSColor(hex: 0x0f1319)
    static let panelRaised = NSColor(hex: 0x131922)
    static let card = NSColor(hex: 0x151b23)
    static let field = NSColor(hex: 0x0b0f14)
    static let hover = NSColor.white.withAlphaComponent(0.065)
    static let selected = NSColor(hex: 0xb8ee55, alpha: 0.095)
    static let line = NSColor.white.withAlphaComponent(0.075)
    static let lineStrong = NSColor.white.withAlphaComponent(0.13)
    static let text = NSColor(hex: 0xf1f4f6)
    static let secondaryText = NSColor(hex: 0xb1b9c2)
    static let muted = NSColor(hex: 0x89939e)
    static let dim = NSColor(hex: 0x616b76)
    static let accent = NSColor(hex: 0xb8ee55)
    static let accentBright = NSColor(hex: 0xd0ff77)
    static let accentSoft = NSColor(hex: 0xb8ee55, alpha: 0.12)
    static let accentLine = NSColor(hex: 0xb8ee55, alpha: 0.30)
    static let danger = NSColor(hex: 0xff8e88)
    static let warning = NSColor(hex: 0xf3c969)
}

final class DeckTitleBar: FlippedView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class DeckLayoutView: FlippedView {
    var layoutHandler: ((CGRect) -> Void)?

    override func layout() {
        super.layout()
        layoutHandler?(bounds)
    }
}

final class DeckFillStackView: NSStackView {
    var horizontalInset: CGFloat = 0

    override func addArrangedSubview(_ view: NSView) {
        super.addArrangedSubview(view)
        guard orientation == .vertical else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: widthAnchor, constant: -horizontalInset).isActive = true
    }
}

final class DeckSegmentedControl: NSSegmentedControl {
    var selectionChanged: (() -> Void)?

    override var selectedSegment: Int {
        didSet {
            needsDisplay = true
            if oldValue != selectedSegment { selectionChanged?() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DeckTheme.panel.setFill()
        bounds.fill()

        guard segmentCount > 0 else { return }
        let segmentWidth = bounds.width / CGFloat(segmentCount)
        for index in 0..<segmentCount {
            let rect = CGRect(x: CGFloat(index) * segmentWidth, y: 0, width: segmentWidth, height: bounds.height)
            let isSelected = index == selectedSegment
            if isSelected {
                let selection = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 5, dy: 8),
                    xRadius: 7,
                    yRadius: 7
                )
                DeckTheme.accentSoft.setFill()
                selection.fill()
                DeckTheme.accentLine.setStroke()
                selection.lineWidth = 0.75
                selection.stroke()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .medium),
                .foregroundColor: isSelected ? DeckTheme.accentBright : DeckTheme.muted
            ]
            let value = NSAttributedString(string: label(forSegment: index) ?? "", attributes: attributes)
            let size = value.size()
            value.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }

        DeckTheme.line.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

final class DeckButton: NSButton {
    var baseFill = NSColor.clear
    var hoverFill = DeckTheme.hover
    var pressedFill = NSColor.white.withAlphaComponent(0.035)
    var stroke = NSColor.clear
    var cornerRadius: CGFloat = 8
    var contentPadding: CGFloat = 12
    var contentSpacing: CGFloat = 7
    private var pointerInside = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        updateDeckAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        updateDeckAppearance(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        setFill(pressedFill, animated: false)
        super.mouseDown(with: event)
        updateDeckAppearance(animated: true)
    }

    func updateDeckAppearance(animated: Bool = false) {
        setFill(pointerInside && isEnabled ? hoverFill : baseFill, animated: animated)
        layer?.borderColor = stroke.cgColor
        layer?.borderWidth = stroke.alphaComponent > 0 ? 1 : 0
        layer?.cornerRadius = cornerRadius
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let tint = (contentTintColor ?? DeckTheme.secondaryText).withAlphaComponent(isEnabled ? 1 : 0.45)
        let hasTitle = !title.isEmpty && imagePosition != .imageOnly
        let hasImage = image != nil && imagePosition != .noImage
        let titleValue = hasTitle ? attributedTitle : NSAttributedString()
        let naturalTitleSize = titleValue.size()
        let symbol = hasImage ? tintedImage(image, color: tint) : nil
        let naturalImageSize = symbol?.size ?? .zero
        let imageSize = NSSize(
            width: min(naturalImageSize.width, 17),
            height: min(naturalImageSize.height, 17)
        )
        let spacing = hasTitle && hasImage ? contentSpacing : 0
        let availableWidth = max(0, bounds.width - contentPadding * 2)
        let contentWidth = min(availableWidth, imageSize.width + spacing + naturalTitleSize.width)
        let startX: CGFloat = alignment == .center
            ? max(contentPadding, bounds.midX - contentWidth / 2)
            : contentPadding

        if let symbol, hasImage {
            let x: CGFloat
            if imagePosition == .imageOnly {
                x = bounds.midX - imageSize.width / 2
            } else if imagePosition == .imageTrailing || imagePosition == .imageRight {
                x = alignment == .center
                    ? startX + contentWidth - imageSize.width
                    : bounds.maxX - contentPadding - imageSize.width
            } else {
                x = startX
            }
            let imageRect = NSRect(
                x: x,
                y: bounds.midY - imageSize.height / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            symbol.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.45, respectFlipped: true, hints: nil)
        }

        if hasTitle {
            let leadingImage = hasImage && imagePosition != .imageTrailing && imagePosition != .imageRight
            let titleX = leadingImage ? startX + imageSize.width + spacing : startX
            let trailingAllowance = hasImage && !leadingImage ? imageSize.width + spacing : 0
            let availableTitleWidth = max(0, bounds.maxX - contentPadding - trailingAllowance - titleX)
            let titleWidth = alignment == .center
                ? min(availableTitleWidth, max(0, contentWidth - imageSize.width - spacing))
                : availableTitleWidth
            let titleRect = NSRect(
                x: titleX,
                y: bounds.midY - naturalTitleSize.height / 2,
                width: titleWidth,
                height: naturalTitleSize.height
            )
            titleValue.draw(
                with: titleRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
        }
    }

    private func tintedImage(_ image: NSImage?, color: NSColor) -> NSImage? {
        guard let image else { return nil }
        guard image.isTemplate else { return image }
        return image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) ?? image
    }

    private func setFill(_ color: NSColor, animated: Bool) {
        guard animated else {
            layer?.backgroundColor = color.cgColor
            return
        }
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = layer?.backgroundColor
        animation.toValue = color.cgColor
        animation.duration = 0.12
        layer?.add(animation, forKey: "deck.hover")
        layer?.backgroundColor = color.cgColor
    }
}

final class DeckCheckboxButton: NSButton {
    private var pointerInside = false

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        toolTip = title
        setButtonType(.pushOnPushOff)
        isBordered = false
        focusRingType = .none
        font = .systemFont(ofSize: 11, weight: .medium)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(140, (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11)]).width + 42), height: 32)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if pointerInside {
            DeckTheme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }

        let box = CGRect(x: 3, y: (bounds.height - 17) / 2, width: 17, height: 17)
        let boxPath = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        (state == .on ? DeckTheme.accent : DeckTheme.field).setFill()
        boxPath.fill()
        (state == .on ? DeckTheme.accent : DeckTheme.lineStrong).setStroke()
        boxPath.lineWidth = 1
        boxPath.stroke()

        if state == .on {
            let check = NSBezierPath()
            check.move(to: CGPoint(x: box.minX + 4.5, y: box.midY))
            check.line(to: CGPoint(x: box.minX + 7.5, y: box.maxY - 4.5))
            check.line(to: CGPoint(x: box.maxX - 4, y: box.minY + 4.5))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor(hex: 0x172206).setStroke()
            check.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: state == .on ? DeckTheme.text : DeckTheme.secondaryText
        ]
        let string = NSAttributedString(string: title, attributes: attributes)
        let textSize = string.size()
        string.draw(at: CGPoint(x: 29, y: (bounds.height - textSize.height) / 2))
    }
}

final class DeckCardView: FlippedView {
    let content = DeckFillStackView()

    init(views: [NSView], spacing: CGFloat = 10) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = DeckTheme.card.cgColor
        layer?.borderColor = DeckTheme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 11

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = spacing
        content.translatesAutoresizingMaskIntoConstraints = false
        views.forEach(content.addArrangedSubview)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

final class DeckFieldCell: NSTextFieldCell {
    private func centeredTextFrame(in frame: NSRect) -> NSRect {
        let horizontalInset: CGFloat = 10
        let usable = frame.insetBy(dx: horizontalInset, dy: 0)
        let textHeight = ceil((font?.ascender ?? 11) - (font?.descender ?? -3))
        return NSRect(
            x: usable.minX,
            y: round(frame.midY - textHeight / 2),
            width: usable.width,
            height: textHeight
        )
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        DeckTheme.field.setFill()
        path.fill()
        let isEditing = controlView.window?.firstResponder === (controlView as? NSTextField)?.currentEditor()
        (isEditing ? DeckTheme.accentLine : DeckTheme.lineStrong).setStroke()
        path.lineWidth = 1
        path.stroke()
        super.drawInterior(withFrame: centeredTextFrame(in: cellFrame), in: controlView)
    }

    override func edit(
        withFrame aRect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(withFrame: centeredTextFrame(in: aRect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame aRect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: centeredTextFrame(in: aRect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

func configureDeckField(_ field: NSTextField, centered: Bool = false) {
    let placeholder = field.placeholderString
    let target = field.target
    let action = field.action
    let cell = DeckFieldCell(textCell: field.stringValue)
    cell.isEditable = true
    cell.isSelectable = true
    cell.isScrollable = true
    cell.lineBreakMode = .byClipping
    cell.focusRingType = .none
    cell.alignment = centered ? .center : field.alignment
    cell.font = field.font
    cell.textColor = DeckTheme.secondaryText
    cell.placeholderString = placeholder
    cell.backgroundColor = .clear
    cell.drawsBackground = false
    field.cell = cell
    field.target = target
    field.action = action
    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
}

func configureDeckPopup(_ popup: NSPopUpButton) {
    popup.isBordered = false
    popup.focusRingType = .none
    popup.contentTintColor = DeckTheme.secondaryText
    popup.font = .systemFont(ofSize: 11, weight: .medium)
    popup.wantsLayer = true
    popup.layer?.backgroundColor = DeckTheme.field.cgColor
    popup.layer?.borderColor = DeckTheme.lineStrong.cgColor
    popup.layer?.borderWidth = 1
    popup.layer?.cornerRadius = 8
}

func configureDeckCheckbox(_ button: NSButton) {
    button.contentTintColor = DeckTheme.accent
    button.font = .systemFont(ofSize: 11, weight: .medium)
    button.focusRingType = .none
}
