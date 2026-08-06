import AppKit
import UniformTypeIdentifiers

enum ScreenshotExportGeometry {
    static func contentBounds(
        imageFrame: CGRect,
        annotationBounds: [CGRect],
        padding: CGFloat,
        constrainedTo canvasBounds: CGRect
    ) -> CGRect {
        var content = imageFrame
        for bounds in annotationBounds where !bounds.isNull && !bounds.isEmpty {
            content = content.union(bounds)
        }
        return content
            .insetBy(dx: -padding, dy: -padding)
            .intersection(canvasBounds)
            .integral
    }
}

enum SnapshotImageRenderer {
    static func image(of view: NSView, rect: CGRect, scale: CGFloat) -> NSImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let resolvedScale = max(1, scale)
        let pixelsWide = max(1, Int(ceil(rect.width * resolvedScale)))
        let pixelsHigh = max(1, Int(ceil(rect.height * resolvedScale)))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        representation.size = rect.size
        view.cacheDisplay(in: rect, to: representation)
        let image = NSImage(size: rect.size)
        image.addRepresentation(representation)
        return image
    }
}

enum ScreenshotTextLayout {
    static func idealWidth(for value: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return max(
            1,
            value.components(separatedBy: .newlines)
                .map { line in
                    ((line.isEmpty ? " " : line) as NSString).size(withAttributes: attributes).width
                }
                .max() ?? 1
        ).rounded(.up) + 2
    }

    static func size(for value: String, font: NSFont, layoutWidth: CGFloat) -> CGSize {
        let resolvedWidth = max(1, layoutWidth)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let drawingValue = value.isEmpty ? " " : value
        let rect = (drawingValue as NSString).boundingRect(
            with: CGSize(width: resolvedWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return CGSize(
            width: ceil(resolvedWidth),
            height: ceil(max(font.boundingRectForFont.height, rect.height))
        )
    }

    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return style
    }
}

enum ScreenshotTextResizeHandle: Equatable {
    case width
    case height
    case both
}

enum ScreenshotTextBoxGeometry {
    static let contentInset = CGSize(width: 10, height: 9)
    static let minimumSize = CGSize(width: 80, height: 44)

    static func defaultSize(for value: String, font: NSFont) -> CGSize {
        let measuredWidth = ScreenshotTextLayout.idealWidth(for: value, font: font)
        let contentWidth = min(440, max(290, measuredWidth + 50))
        let textSize = ScreenshotTextLayout.size(
            for: value,
            font: font,
            layoutWidth: contentWidth
        )
        return sizeEnsuringTextFits(CGSize(
            width: contentWidth + contentInset.width * 2,
            height: min(220, max(116, textSize.height + 44))
        ), value: value, font: font)
    }

    static func contentRect(in frame: CGRect) -> CGRect {
        frame.insetBy(dx: contentInset.width, dy: contentInset.height)
    }

    static func point(for handle: ScreenshotTextResizeHandle, in frame: CGRect) -> CGPoint {
        switch handle {
        case .width: return CGPoint(x: frame.maxX, y: frame.midY)
        case .height: return CGPoint(x: frame.midX, y: frame.maxY)
        case .both: return CGPoint(x: frame.maxX, y: frame.maxY)
        }
    }

    static func handle(at point: CGPoint, in frame: CGRect) -> ScreenshotTextResizeHandle? {
        let handles: [ScreenshotTextResizeHandle] = [.both, .width, .height]
        return handles.first { handle in
            let handlePoint = self.point(for: handle, in: frame)
            return hypot(point.x - handlePoint.x, point.y - handlePoint.y) <= 12
        }
    }

    static func resizedSize(
        _ size: CGSize,
        using handle: ScreenshotTextResizeHandle,
        translation: CGSize,
        value: String,
        font: NSFont
    ) -> CGSize {
        var result = size
        if handle == .width || handle == .both {
            result.width = max(minimumSize.width, size.width + translation.width)
        }
        if handle == .height || handle == .both {
            result.height = max(minimumSize.height, size.height + translation.height)
        }
        return sizeEnsuringTextFits(result, value: value, font: font)
    }

    static func sizeEnsuringTextFits(_ size: CGSize, value: String, font: NSFont) -> CGSize {
        let width = max(minimumSize.width, size.width)
        let contentWidth = max(1, width - contentInset.width * 2)
        let textHeight = ScreenshotTextLayout.size(
            for: value,
            font: font,
            layoutWidth: contentWidth
        ).height
        let minimumHeight = max(
            minimumSize.height,
            ceil(textHeight + contentInset.height * 2)
        )
        return CGSize(width: width, height: max(minimumHeight, size.height))
    }
}

enum ScreenshotArrowGeometry {
    static func defaultControl(start: CGPoint, end: CGPoint) -> CGPoint {
        CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    static func point(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let remaining = 1 - t
        return CGPoint(
            x: remaining * remaining * start.x + 2 * remaining * t * control.x + t * t * end.x,
            y: remaining * remaining * start.y + 2 * remaining * t * control.y + t * t * end.y
        )
    }

    static func curvePoint(start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        point(start: start, control: control, end: end, t: 0.5)
    }

    static func control(start: CGPoint, curvePoint: CGPoint, end: CGPoint) -> CGPoint {
        CGPoint(
            x: 2 * curvePoint.x - (start.x + end.x) / 2,
            y: 2 * curvePoint.y - (start.y + end.y) / 2
        )
    }

    static func bounds(start: CGPoint, control: CGPoint, end: CGPoint) -> CGRect {
        var points = [start, end]
        appendExtremum(start: start.x, control: control.x, end: end.x) { t in
            points.append(point(start: start, control: control, end: end, t: t))
        }
        appendExtremum(start: start.y, control: control.y, end: end.y) { t in
            points.append(point(start: start, control: control, end: end, t: t))
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(
            x: xs.min() ?? start.x,
            y: ys.min() ?? start.y,
            width: (xs.max() ?? start.x) - (xs.min() ?? start.x),
            height: (ys.max() ?? start.y) - (ys.min() ?? start.y)
        )
    }

    static func headPoints(
        start: CGPoint,
        control: CGPoint,
        end: CGPoint,
        lineWidth: CGFloat
    ) -> (CGPoint, CGPoint) {
        var tangent = CGSize(width: end.x - control.x, height: end.y - control.y)
        if hypot(tangent.width, tangent.height) < 0.01 {
            tangent = CGSize(width: end.x - start.x, height: end.y - start.y)
        }
        let angle = atan2(tangent.height, tangent.width)
        let headLength = max(13, lineWidth * 4.2)
        let headSpread: CGFloat = .pi / 6.2
        return (
            CGPoint(
                x: end.x - headLength * cos(angle - headSpread),
                y: end.y - headLength * sin(angle - headSpread)
            ),
            CGPoint(
                x: end.x - headLength * cos(angle + headSpread),
                y: end.y - headLength * sin(angle + headSpread)
            )
        )
    }

    static func renderedBounds(
        start: CGPoint,
        control: CGPoint,
        end: CGPoint,
        lineWidth: CGFloat
    ) -> CGRect {
        let expansion = lineWidth / 2 + 6
        var result = bounds(start: start, control: control, end: end)
            .insetBy(dx: -expansion, dy: -expansion)
        let head = headPoints(start: start, control: control, end: end, lineWidth: lineWidth)
        for point in [head.0, head.1] {
            result = result.union(
                CGRect(
                    x: point.x - expansion,
                    y: point.y - expansion,
                    width: expansion * 2,
                    height: expansion * 2
                )
            )
        }
        return result
    }

    static func distance(
        from point: CGPoint,
        toCurveFrom start: CGPoint,
        control: CGPoint,
        end: CGPoint
    ) -> CGFloat {
        let approximateLength =
            hypot(control.x - start.x, control.y - start.y) +
            hypot(end.x - control.x, end.y - control.y)
        let segmentCount = max(20, min(80, Int(ceil(approximateLength / 8))))
        var nearest = CGFloat.greatestFiniteMagnitude
        var previous = start
        for index in 1...segmentCount {
            let current = self.point(
                start: start,
                control: control,
                end: end,
                t: CGFloat(index) / CGFloat(segmentCount)
            )
            nearest = min(nearest, distance(from: point, toSegmentFrom: previous, to: current))
            previous = current
        }
        return nearest
    }

    private static func appendExtremum(
        start: CGFloat,
        control: CGFloat,
        end: CGFloat,
        append: (CGFloat) -> Void
    ) {
        let denominator = start - 2 * control + end
        guard abs(denominator) > 0.0001 else { return }
        let t = (start - control) / denominator
        if t > 0, t < 1 { append(t) }
    }

    private static func distance(
        from point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength))
        let closest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}

private enum ScreenshotTool: Int {
    case select
    case draw
    case arrow
    case text
}

private struct ScreenshotSelectionStyle {
    var color: NSColor
    var lineWidth: CGFloat
    var kindTitle: String
    var isText: Bool
    var isArrow: Bool
}

private struct ScreenshotAnnotation {
    enum Kind {
        case stroke([CGPoint])
        case arrow(start: CGPoint, control: CGPoint, end: CGPoint)
        case text(value: String, origin: CGPoint, boxSize: CGSize)
    }

    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat

    var textFont: NSFont {
        let weight: NSFont.Weight
        switch lineWidth {
        case ..<2.5: weight = .regular
        case ..<5.5: weight = .medium
        case ..<8.5: weight = .bold
        default: weight = .heavy
        }
        return .systemFont(ofSize: 22, weight: weight)
    }

    var kindTitle: String {
        switch kind {
        case .stroke: return "drawing"
        case .arrow: return "arrow"
        case .text: return "text"
        }
    }

    var isText: Bool {
        if case .text = kind { return true }
        return false
    }

    var isArrow: Bool {
        if case .arrow = kind { return true }
        return false
    }

    mutating func ensureTextFits() {
        guard case .text(let value, let origin, let boxSize) = kind else { return }
        kind = .text(
            value: value,
            origin: origin,
            boxSize: ScreenshotTextBoxGeometry.sizeEnsuringTextFits(
                boxSize,
                value: value,
                font: textFont
            )
        )
    }

    var bounds: CGRect {
        switch kind {
        case .stroke(let points):
            guard let first = points.first else { return .null }
            var result = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                result = result.union(CGRect(origin: point, size: .zero))
            }
            return result.insetBy(dx: -(lineWidth + 5), dy: -(lineWidth + 5))
        case .arrow(let start, let control, let end):
            return ScreenshotArrowGeometry.renderedBounds(
                start: start,
                control: control,
                end: end,
                lineWidth: lineWidth
            )
        case .text(_, let origin, let boxSize):
            return CGRect(origin: origin, size: boxSize)
        }
    }

    mutating func offset(by delta: CGSize) {
        switch kind {
        case .stroke(let points):
            kind = .stroke(points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) })
        case .arrow(let start, let control, let end):
            kind = .arrow(
                start: CGPoint(x: start.x + delta.width, y: start.y + delta.height),
                control: CGPoint(x: control.x + delta.width, y: control.y + delta.height),
                end: CGPoint(x: end.x + delta.width, y: end.y + delta.height)
            )
        case .text(let value, let origin, let boxSize):
            kind = .text(
                value: value,
                origin: CGPoint(x: origin.x + delta.width, y: origin.y + delta.height),
                boxSize: boxSize
            )
        }
    }

    func contains(_ point: CGPoint) -> Bool {
        switch kind {
        case .text:
            return bounds.insetBy(dx: -6, dy: -6).contains(point)
        case .stroke(let points):
            return pointsOnPath(points, areNear: point)
        case .arrow(let start, let control, let end):
            return ScreenshotArrowGeometry.distance(
                from: point,
                toCurveFrom: start,
                control: control,
                end: end
            ) <= max(9, lineWidth + 6)
        }
    }

    func draw(offset: CGSize = .zero, selected: Bool = false) {
        let translated: (CGPoint) -> CGPoint = {
            CGPoint(x: $0.x + offset.width, y: $0.y + offset.height)
        }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.set()
        color.setStroke()
        color.setFill()
        switch kind {
        case .stroke(let points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: translated(first))
            for point in points.dropFirst() { path.line(to: translated(point)) }
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        case .arrow(let start, let control, let end):
            let resolvedStart = translated(start)
            let resolvedControl = translated(control)
            let resolvedEnd = translated(end)
            let path = NSBezierPath()
            path.move(to: resolvedStart)
            path.curve(
                to: resolvedEnd,
                controlPoint1: CGPoint(
                    x: resolvedStart.x + 2 * (resolvedControl.x - resolvedStart.x) / 3,
                    y: resolvedStart.y + 2 * (resolvedControl.y - resolvedStart.y) / 3
                ),
                controlPoint2: CGPoint(
                    x: resolvedEnd.x + 2 * (resolvedControl.x - resolvedEnd.x) / 3,
                    y: resolvedEnd.y + 2 * (resolvedControl.y - resolvedEnd.y) / 3
                )
            )
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.stroke()

            let headPoints = ScreenshotArrowGeometry.headPoints(
                start: resolvedStart,
                control: resolvedControl,
                end: resolvedEnd,
                lineWidth: lineWidth
            )
            let head = NSBezierPath()
            head.move(to: resolvedEnd)
            head.line(to: headPoints.0)
            head.move(to: resolvedEnd)
            head.line(to: headPoints.1)
            head.lineWidth = lineWidth
            head.lineCapStyle = .round
            head.lineJoinStyle = .round
            head.stroke()
        case .text(let value, let origin, let boxSize):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: color,
                .paragraphStyle: ScreenshotTextLayout.paragraphStyle()
            ]
            let frame = CGRect(origin: translated(origin), size: boxSize)
            (value as NSString).draw(
                with: ScreenshotTextBoxGeometry.contentRect(in: frame),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        if selected, case .arrow(let start, let control, let end) = kind {
            drawArrowSelection(
                start: translated(start),
                control: translated(control),
                end: translated(end)
            )
        } else if selected, case .text(_, let origin, let boxSize) = kind {
            drawTextSelection(frame: CGRect(origin: translated(origin), size: boxSize))
        } else if selected {
            let selectionBounds = bounds
                .offsetBy(dx: offset.width, dy: offset.height)
                .insetBy(dx: -7, dy: -7)
            let selection = NSBezierPath(roundedRect: selectionBounds, xRadius: 5, yRadius: 5)
            selection.lineWidth = 1.25
            NSColor(hex: 0x93d7ff, alpha: 0.95).setStroke()
            selection.stroke()
            for corner in [
                CGPoint(x: selectionBounds.minX, y: selectionBounds.minY),
                CGPoint(x: selectionBounds.maxX, y: selectionBounds.minY),
                CGPoint(x: selectionBounds.minX, y: selectionBounds.maxY),
                CGPoint(x: selectionBounds.maxX, y: selectionBounds.maxY)
            ] {
                let handle = NSBezierPath(ovalIn: CGRect(x: corner.x - 3, y: corner.y - 3, width: 6, height: 6))
                NSColor(hex: 0x93d7ff).setFill()
                handle.fill()
                NSColor(hex: 0x0b1118).setStroke()
                handle.lineWidth = 1
                handle.stroke()
            }
        }
    }

    private func drawTextSelection(frame: CGRect) {
        let accent = NSColor(hex: 0x93d7ff)
        let selection = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        selection.lineWidth = 1.25
        accent.withAlphaComponent(0.95).setStroke()
        selection.stroke()

        for handle in [
            ScreenshotTextResizeHandle.width,
            .height,
            .both
        ] {
            let point = ScreenshotTextBoxGeometry.point(for: handle, in: frame)
            let path = NSBezierPath(roundedRect: CGRect(
                x: point.x - 4,
                y: point.y - 4,
                width: 8,
                height: 8
            ), xRadius: 2, yRadius: 2)
            accent.setFill()
            path.fill()
            NSColor(hex: 0x0b1118).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawArrowSelection(start: CGPoint, control: CGPoint, end: CGPoint) {
        let accent = NSColor(hex: 0x93d7ff)
        let curvePoint = ScreenshotArrowGeometry.curvePoint(
            start: start,
            control: control,
            end: end
        )
        let chordMidpoint = ScreenshotArrowGeometry.defaultControl(start: start, end: end)

        let curveGuide = NSBezierPath()
        curveGuide.move(to: chordMidpoint)
        curveGuide.line(to: curvePoint)
        curveGuide.lineWidth = 1
        curveGuide.setLineDash([3, 3], count: 2, phase: 0)
        accent.withAlphaComponent(0.72).setStroke()
        curveGuide.stroke()

        drawArrowHandle(at: start, shape: .origin, accent: accent)
        drawArrowHandle(at: curvePoint, shape: .curve, accent: accent)
        drawArrowHandle(at: end, shape: .point, accent: accent)
    }

    private enum ArrowHandleShape {
        case origin
        case curve
        case point
    }

    private func drawArrowHandle(at point: CGPoint, shape: ArrowHandleShape, accent: NSColor) {
        let path: NSBezierPath
        switch shape {
        case .origin:
            path = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        case .curve:
            path = NSBezierPath()
            path.move(to: CGPoint(x: point.x, y: point.y - 6))
            path.line(to: CGPoint(x: point.x + 6, y: point.y))
            path.line(to: CGPoint(x: point.x, y: point.y + 6))
            path.line(to: CGPoint(x: point.x - 6, y: point.y))
            path.close()
        case .point:
            path = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        }
        (shape == .point ? accent : NSColor(hex: 0x0b1118)).setFill()
        path.fill()
        accent.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func pointsOnPath(_ points: [CGPoint], areNear point: CGPoint) -> Bool {
        guard points.count > 1 else {
            guard let first = points.first else { return false }
            return hypot(point.x - first.x, point.y - first.y) <= max(9, lineWidth + 6)
        }
        for index in 1..<points.count {
            if distance(from: point, toSegmentFrom: points[index - 1], to: points[index]) <= max(9, lineWidth + 6) {
                return true
            }
        }
        return false
    }

    private func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength))
        let closest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}

private final class MultilineAnnotationTextView: NSTextView {
    var finishEditing: (() -> Void)?
    var cancelEditing: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            finishEditing?()
            return
        }
        if event.keyCode == 53 {
            cancelEditing?()
            return
        }
        super.keyDown(with: event)
    }
}

private enum ScreenshotSelectionInteraction {
    case move
    case arrowOrigin
    case arrowCurve
    case arrowPoint
    case textResize(ScreenshotTextResizeHandle)

    var undoActionName: String {
        switch self {
        case .move: return "Move Markup"
        case .arrowOrigin: return "Change Arrow Origin"
        case .arrowCurve: return "Curve Arrow"
        case .arrowPoint: return "Change Arrow Point"
        case .textResize: return "Resize Text Box"
        }
    }
}

private final class ScreenshotCanvasView: FlippedView, NSTextViewDelegate {
    let screenshot: NSImage
    let screenshotFrame: CGRect
    var onStateChange: (() -> Void)?

    private(set) var tool: ScreenshotTool = .draw
    var annotationColor = NSColor(hex: 0xff5f57)
    var annotationLineWidth: CGFloat = 4

    private var annotations: [ScreenshotAnnotation] = []
    private var selectedIndex: Int?
    private var interactionStart: CGPoint?
    private var interactionStartAnnotations: [ScreenshotAnnotation]?
    private var originalSelectedAnnotation: ScreenshotAnnotation?
    private var selectionInteraction: ScreenshotSelectionInteraction?
    private let annotationUndoManager = UndoManager()
    private var editingTextView: NSTextView?
    private var editingContainer: NSScrollView?
    private var editingAnnotationIndex: Int?
    private var editingPreviousAnnotations: [ScreenshotAnnotation]?
    private var isExporting = false

    init(image: NSImage) {
        screenshot = image
        let workspaceSize = CGSize(
            width: max(1_600, image.size.width + 900),
            height: max(1_200, image.size.height + 760)
        )
        screenshotFrame = CGRect(
            x: (workspaceSize.width - image.size.width) / 2,
            y: (workspaceSize.height - image.size.height) / 2,
            width: image.size.width,
            height: image.size.height
        )
        super.init(frame: CGRect(origin: .zero, size: workspaceSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x0b1118).cgColor
        setAccessibilityLabel("Screenshot markup canvas")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { annotationUndoManager }

    var canUndo: Bool { annotationUndoManager.canUndo }
    var canRedo: Bool { annotationUndoManager.canRedo }
    var hasAnnotations: Bool { !annotations.isEmpty }
    var isEditingText: Bool { editingTextView != nil }
    var selectionStyle: ScreenshotSelectionStyle? {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return nil }
        let annotation = annotations[selectedIndex]
        return ScreenshotSelectionStyle(
            color: annotation.color,
            lineWidth: annotation.lineWidth,
            kindTitle: annotation.kindTitle,
            isText: annotation.isText,
            isArrow: annotation.isArrow
        )
    }

    func setTool(_ tool: ScreenshotTool) {
        commitTextEditing()
        self.tool = tool
        selectedIndex = nil
        selectionInteraction = nil
        needsDisplay = true
        invalidateCursorRects()
        window?.makeFirstResponder(self)
        onStateChange?()
    }

    func undoChange() {
        commitTextEditing()
        annotationUndoManager.undo()
        onStateChange?()
    }

    func redoChange() {
        commitTextEditing()
        annotationUndoManager.redo()
        onStateChange?()
    }

    func updateColor(_ color: NSColor) {
        annotationColor = color
        editingTextView?.textColor = color
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else {
            onStateChange?()
            return
        }
        guard !annotations[selectedIndex].color.isEqual(color) else { return }
        let previous = annotations
        annotations[selectedIndex].color = color
        registerUndo(previous: previous, actionName: "Change Color")
        needsDisplay = true
        onStateChange?()
    }

    func updateLineWidth(_ lineWidth: CGFloat) {
        let resolvedWidth = max(1, min(12, lineWidth))
        annotationLineWidth = resolvedWidth
        if let editingTextView {
            editingTextView.font = ScreenshotAnnotation(
                kind: .text(value: editingTextView.string, origin: .zero, boxSize: .zero),
                color: editingTextView.textColor ?? annotationColor,
                lineWidth: resolvedWidth
            ).textFont
            growEditingTextBoxToFitText()
        }
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else {
            onStateChange?()
            return
        }
        guard abs(annotations[selectedIndex].lineWidth - resolvedWidth) > 0.01 else { return }
        let previous = annotations
        annotations[selectedIndex].lineWidth = resolvedWidth
        annotations[selectedIndex].ensureTextFits()
        registerUndo(previous: previous, actionName: "Change Thickness")
        needsDisplay = true
        onStateChange?()
    }

    func clearAnnotations() {
        commitTextEditing()
        guard !annotations.isEmpty else { return }
        let previous = annotations
        annotations.removeAll()
        selectedIndex = nil
        registerUndo(previous: previous, actionName: "Clear Markup")
        needsDisplay = true
        onStateChange?()
    }

    func exportImage() -> NSImage? {
        commitTextEditing()
        let crop = ScreenshotExportGeometry.contentBounds(
            imageFrame: screenshotFrame,
            annotationBounds: annotations.map(\.bounds),
            padding: 24,
            constrainedTo: bounds
        )
        let sourceScale = screenshot.representations
            .compactMap { representation -> CGFloat? in
                guard representation.size.width > 0 else { return nil }
                return CGFloat(representation.pixelsWide) / representation.size.width
            }
            .max() ?? 2
        isExporting = true
        needsDisplay = true
        defer {
            isExporting = false
            needsDisplay = true
        }
        return SnapshotImageRenderer.image(
            of: self,
            rect: crop,
            scale: min(3, max(2, sourceScale))
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(hex: 0x10161e).setFill()
        dirtyRect.fill()
        drawGrid(in: dirtyRect)
        if !isExporting {
            drawScreenshotStage()
        }

        screenshot.draw(
            in: screenshotFrame,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        for (index, annotation) in annotations.enumerated() {
            annotation.draw(selected: !isExporting && index == selectedIndex)
        }
    }

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        interactionStart = point

        switch tool {
        case .select:
            if let handleInteraction = selectedArrowHandle(at: point) {
                selectionInteraction = handleInteraction
            } else if let handle = selectedTextResizeHandle(at: point) {
                selectionInteraction = .textResize(handle)
            } else {
                selectedIndex = annotations.indices.reversed().first { annotations[$0].contains(point) }
                selectionInteraction = selectedIndex == nil ? nil : .move
            }
            if let selectedIndex {
                let selected = annotations[selectedIndex]
                annotationColor = selected.color
                annotationLineWidth = selected.lineWidth
                if event.clickCount >= 2, selected.isText {
                    beginTextEditing(annotationAt: selectedIndex)
                    interactionStart = nil
                    interactionStartAnnotations = nil
                    originalSelectedAnnotation = nil
                    needsDisplay = true
                    onStateChange?()
                    return
                }
                originalSelectedAnnotation = selected
            } else {
                originalSelectedAnnotation = nil
            }
            interactionStartAnnotations = annotations
        case .draw:
            interactionStartAnnotations = annotations
            annotations.append(ScreenshotAnnotation(
                kind: .stroke([point]),
                color: annotationColor,
                lineWidth: annotationLineWidth
            ))
            selectedIndex = annotations.count - 1
        case .arrow:
            interactionStartAnnotations = annotations
            annotations.append(ScreenshotAnnotation(
                kind: .arrow(start: point, control: point, end: point),
                color: annotationColor,
                lineWidth: annotationLineWidth
            ))
            selectedIndex = annotations.count - 1
        case .text:
            beginTextEditing(at: point)
        }
        needsDisplay = true
        invalidateCursorRects()
        onStateChange?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = interactionStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch tool {
        case .select:
            guard let index = selectedIndex, let originalSelectedAnnotation else { return }
            switch selectionInteraction ?? .move {
            case .move:
                var moved = originalSelectedAnnotation
                moved.offset(by: CGSize(width: point.x - start.x, height: point.y - start.y))
                annotations[index] = moved
            case .arrowOrigin:
                guard case .arrow(let origin, let control, let arrowPoint) = originalSelectedAnnotation.kind else {
                    return
                }
                let curvePoint = ScreenshotArrowGeometry.curvePoint(
                    start: origin,
                    control: control,
                    end: arrowPoint
                )
                annotations[index].kind = .arrow(
                    start: point,
                    control: ScreenshotArrowGeometry.control(
                        start: point,
                        curvePoint: curvePoint,
                        end: arrowPoint
                    ),
                    end: arrowPoint
                )
            case .arrowCurve:
                guard case .arrow(let origin, _, let arrowPoint) = originalSelectedAnnotation.kind else {
                    return
                }
                annotations[index].kind = .arrow(
                    start: origin,
                    control: ScreenshotArrowGeometry.control(
                        start: origin,
                        curvePoint: point,
                        end: arrowPoint
                    ),
                    end: arrowPoint
                )
            case .arrowPoint:
                guard case .arrow(let origin, let control, let arrowPoint) = originalSelectedAnnotation.kind else {
                    return
                }
                let curvePoint = ScreenshotArrowGeometry.curvePoint(
                    start: origin,
                    control: control,
                    end: arrowPoint
                )
                annotations[index].kind = .arrow(
                    start: origin,
                    control: ScreenshotArrowGeometry.control(
                        start: origin,
                        curvePoint: curvePoint,
                        end: point
                    ),
                    end: point
                )
            case .textResize(let handle):
                guard case .text(let value, let origin, let boxSize) = originalSelectedAnnotation.kind else {
                    return
                }
                annotations[index].kind = .text(
                    value: value,
                    origin: origin,
                    boxSize: ScreenshotTextBoxGeometry.resizedSize(
                        boxSize,
                        using: handle,
                        translation: CGSize(width: point.x - start.x, height: point.y - start.y),
                        value: value,
                        font: originalSelectedAnnotation.textFont
                    )
                )
            }
        case .draw:
            guard let index = selectedIndex,
                  case .stroke(var points) = annotations[index].kind else { return }
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 1.5 {
                points.append(point)
                annotations[index].kind = .stroke(points)
            }
        case .arrow:
            guard let index = selectedIndex,
                  case .arrow(let arrowStart, _, _) = annotations[index].kind else { return }
            annotations[index].kind = .arrow(
                start: arrowStart,
                control: ScreenshotArrowGeometry.defaultControl(start: arrowStart, end: point),
                end: point
            )
        case .text:
            break
        }
        needsDisplay = true
        invalidateCursorRects()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            interactionStart = nil
            interactionStartAnnotations = nil
            originalSelectedAnnotation = nil
            selectionInteraction = nil
            invalidateCursorRects()
            onStateChange?()
        }
        guard let previous = interactionStartAnnotations else { return }
        switch tool {
        case .select:
            guard let start = interactionStart else { return }
            let end = convert(event.locationInWindow, from: nil)
            if hypot(end.x - start.x, end.y - start.y) > 0.5 {
                registerUndo(
                    previous: previous,
                    actionName: (selectionInteraction ?? .move).undoActionName
                )
            }
        case .draw:
            guard let index = selectedIndex,
                  case .stroke(let points) = annotations[index].kind else { return }
            if points.count < 2 {
                annotations.remove(at: index)
                selectedIndex = nil
            } else {
                registerUndo(previous: previous, actionName: "Draw")
            }
        case .arrow:
            guard let index = selectedIndex,
                  case .arrow(let start, _, let end) = annotations[index].kind else { return }
            if hypot(end.x - start.x, end.y - start.y) < 4 {
                annotations.remove(at: index)
                selectedIndex = nil
            } else {
                registerUndo(previous: previous, actionName: "Add Arrow")
            }
        case .text:
            break
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command), characters == "z" {
            event.modifierFlags.contains(.shift) ? redoChange() : undoChange()
            return
        }
        if characters == "\u{7f}" || characters == "\u{f728}" {
            deleteSelectedAnnotation()
            return
        }
        if characters == "\u{1b}" {
            selectedIndex = nil
            needsDisplay = true
            invalidateCursorRects()
            onStateChange?()
            return
        }
        if (characters == "\r" || characters == "\n"),
           let selectedIndex,
           annotations.indices.contains(selectedIndex),
           annotations[selectedIndex].isText {
            beginTextEditing(annotationAt: selectedIndex)
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch characters {
            case "v": setTool(.select); return
            case "d": setTool(.draw); return
            case "a": setTool(.arrow); return
            case "t": setTool(.text); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor
        switch tool {
        case .select: cursor = .arrow
        case .draw, .arrow: cursor = .crosshair
        case .text: cursor = .iBeam
        }
        addCursorRect(bounds, cursor: cursor)
        guard tool == .select,
              let selectedIndex,
              annotations.indices.contains(selectedIndex) else {
            return
        }
        switch annotations[selectedIndex].kind {
        case .arrow(let start, let control, let end):
            let curvePoint = ScreenshotArrowGeometry.curvePoint(start: start, control: control, end: end)
            for point in [start, curvePoint, end] {
                addCursorRect(
                    CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20),
                    cursor: .crosshair
                )
            }
        case .text(_, let origin, let boxSize):
            let frame = CGRect(origin: origin, size: boxSize)
            for (handle, cursor) in [
                (ScreenshotTextResizeHandle.width, NSCursor.resizeLeftRight),
                (.height, NSCursor.resizeUpDown),
                (.both, NSCursor.crosshair)
            ] {
                let point = ScreenshotTextBoxGeometry.point(for: handle, in: frame)
                addCursorRect(
                    CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20),
                    cursor: cursor
                )
            }
        case .stroke:
            break
        }
    }

    private func selectedArrowHandle(at point: CGPoint) -> ScreenshotSelectionInteraction? {
        guard let selectedIndex,
              annotations.indices.contains(selectedIndex),
              case .arrow(let start, let control, let end) = annotations[selectedIndex].kind else {
            return nil
        }
        let handles: [(CGPoint, ScreenshotSelectionInteraction)] = [
            (end, .arrowPoint),
            (start, .arrowOrigin),
            (
                ScreenshotArrowGeometry.curvePoint(start: start, control: control, end: end),
                .arrowCurve
            )
        ]
        return handles.first { handle, _ in
            hypot(point.x - handle.x, point.y - handle.y) <= 12
        }?.1
    }

    private func selectedTextResizeHandle(at point: CGPoint) -> ScreenshotTextResizeHandle? {
        guard let selectedIndex,
              annotations.indices.contains(selectedIndex),
              case .text(_, let origin, let boxSize) = annotations[selectedIndex].kind else {
            return nil
        }
        return ScreenshotTextBoxGeometry.handle(
            at: point,
            in: CGRect(origin: origin, size: boxSize)
        )
    }

    private func invalidateCursorRects() {
        guard let window else { return }
        window.invalidateCursorRects(for: self)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                commitTextEditing()
                return true
            }
            return false
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        growEditingTextBoxToFitText()
    }

    private func drawGrid(in dirtyRect: CGRect) {
        let color = NSColor(hex: 0xa9c6dd, alpha: 0.045)
        color.setFill()
        let spacing: CGFloat = 32
        let startX = floor(dirtyRect.minX / spacing) * spacing
        let startY = floor(dirtyRect.minY / spacing) * spacing
        var x = startX
        while x <= dirtyRect.maxX {
            var y = startY
            while y <= dirtyRect.maxY {
                NSBezierPath(ovalIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)).fill()
                y += spacing
            }
            x += spacing
        }
    }

    private func drawScreenshotStage() {
        let stage = screenshotFrame.insetBy(dx: -16, dy: -16)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.48)
        shadow.shadowBlurRadius = 34
        shadow.shadowOffset = CGSize(width: 0, height: -12)
        shadow.set()
        NSColor(hex: 0x080b0f).setFill()
        NSBezierPath(roundedRect: stage, xRadius: 16, yRadius: 16).fill()
        NSGraphicsContext.restoreGraphicsState()

        let stagePath = NSBezierPath(roundedRect: stage, xRadius: 16, yRadius: 16)
        NSColor(hex: 0x1b2430).setFill()
        stagePath.fill()
        NSColor.white.withAlphaComponent(0.09).setStroke()
        stagePath.lineWidth = 1
        stagePath.stroke()

        let label = "SCREEN  ·  \(Int(screenshotFrame.width)) × \(Int(screenshotFrame.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: NSColor(hex: 0x8a98a7)
        ]
        (label as NSString).draw(
            at: CGPoint(x: stage.minX + 2, y: stage.minY - 27),
            withAttributes: attributes
        )
    }

    private func beginTextEditing(at point: CGPoint) {
        presentTextEditor(
            at: point,
            value: "",
            color: annotationColor,
            lineWidth: annotationLineWidth,
            boxSize: nil,
            annotationIndex: nil
        )
    }

    private func beginTextEditing(annotationAt index: Int) {
        guard annotations.indices.contains(index),
              case .text(let value, let origin, let boxSize) = annotations[index].kind else { return }
        let annotation = annotations[index]
        presentTextEditor(
            at: origin,
            value: value,
            color: annotation.color,
            lineWidth: annotation.lineWidth,
            boxSize: boxSize,
            annotationIndex: index
        )
    }

    private func presentTextEditor(
        at point: CGPoint,
        value: String,
        color: NSColor,
        lineWidth: CGFloat,
        boxSize: CGSize?,
        annotationIndex: Int?
    ) {
        let annotation = ScreenshotAnnotation(
            kind: .text(value: value, origin: point, boxSize: boxSize ?? .zero),
            color: color,
            lineWidth: lineWidth
        )
        let requestedBoxSize = boxSize
            ?? ScreenshotTextBoxGeometry.defaultSize(for: value, font: annotation.textFont)
        let resolvedBoxSize = ScreenshotTextBoxGeometry.sizeEnsuringTextFits(
            requestedBoxSize,
            value: value,
            font: annotation.textFont
        )
        let container = NSScrollView(frame: CGRect(origin: point, size: resolvedBoxSize))
        container.drawsBackground = true
        container.backgroundColor = NSColor(hex: 0x121820, alpha: 0.98)
        container.borderType = .noBorder
        container.hasVerticalScroller = true
        container.autohidesScrollers = true
        container.scrollerStyle = .overlay
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.layer?.borderWidth = 1.5
        container.layer?.borderColor = NSColor(hex: 0x93d7ff).cgColor
        container.layer?.masksToBounds = true

        let textView = MultilineAnnotationTextView(frame: container.contentView.bounds)
        textView.string = value
        textView.font = annotation.textFont
        textView.textColor = color
        textView.backgroundColor = .clear
        textView.insertionPointColor = NSColor(hex: 0x93d7ff)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = ScreenshotTextBoxGeometry.contentInset
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self
        textView.finishEditing = { [weak self] in self?.commitTextEditing() }
        textView.cancelEditing = { [weak self] in self?.cancelTextEditing() }
        textView.setAccessibilityLabel("Text annotation")
        textView.setAccessibilityPlaceholderValue("Type a note. Command-Return finishes editing.")
        container.documentView = textView

        editingTextView = textView
        editingContainer = container
        editingAnnotationIndex = annotationIndex
        editingPreviousAnnotations = annotations
        selectedIndex = annotationIndex
        addSubview(container)
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: (value as NSString).length))
        needsDisplay = true
        onStateChange?()
    }

    private func growEditingTextBoxToFitText() {
        guard let textView = editingTextView,
              let container = editingContainer,
              let font = textView.font else { return }
        let resolvedSize = ScreenshotTextBoxGeometry.sizeEnsuringTextFits(
            container.frame.size,
            value: textView.string,
            font: font
        )
        guard resolvedSize.height > container.frame.height + 0.5 else { return }
        var frame = container.frame
        frame.size.height = resolvedSize.height
        container.frame = frame
        needsDisplay = true
        onStateChange?()
    }

    private func commitTextEditing() {
        guard let textView = editingTextView, let container = editingContainer else { return }
        let annotationIndex = editingAnnotationIndex
        let previous = editingPreviousAnnotations ?? annotations
        let color = textView.textColor ?? annotationColor
        let origin = container.frame.origin
        let value = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let font = textView.font ?? NSFont.systemFont(ofSize: 22)
        let boxSize = ScreenshotTextBoxGeometry.sizeEnsuringTextFits(
            container.frame.size,
            value: value,
            font: font
        )
        editingTextView = nil
        editingContainer = nil
        editingAnnotationIndex = nil
        editingPreviousAnnotations = nil
        textView.enclosingScrollView?.removeFromSuperview()
        if let annotationIndex, annotations.indices.contains(annotationIndex) {
            if value.isEmpty {
                annotations.remove(at: annotationIndex)
                selectedIndex = nil
            } else {
                annotations[annotationIndex].kind = .text(
                    value: value,
                    origin: origin,
                    boxSize: boxSize
                )
                selectedIndex = annotationIndex
            }
            registerUndo(previous: previous, actionName: "Edit Text")
        } else if !value.isEmpty {
            annotations.append(ScreenshotAnnotation(
                kind: .text(value: value, origin: origin, boxSize: boxSize),
                color: color,
                lineWidth: annotationLineWidth
            ))
            selectedIndex = annotations.count - 1
            registerUndo(previous: previous, actionName: "Add Text")
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
        onStateChange?()
    }

    private func cancelTextEditing() {
        editingContainer?.removeFromSuperview()
        editingTextView = nil
        editingContainer = nil
        editingAnnotationIndex = nil
        editingPreviousAnnotations = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
        onStateChange?()
    }

    private func deleteSelectedAnnotation() {
        commitTextEditing()
        guard let index = selectedIndex, annotations.indices.contains(index) else { return }
        let previous = annotations
        annotations.remove(at: index)
        selectedIndex = nil
        registerUndo(previous: previous, actionName: "Delete Markup")
        needsDisplay = true
        onStateChange?()
    }

    private func registerUndo(previous: [ScreenshotAnnotation], actionName: String) {
        annotationUndoManager.registerUndo(withTarget: self) { target in
            let current = target.annotations
            target.annotations = previous
            target.selectedIndex = nil
            target.registerUndo(previous: current, actionName: actionName)
            target.needsDisplay = true
            target.onStateChange?()
        }
        annotationUndoManager.setActionName(actionName)
    }
}

final class ScreenshotEditorController: NSObject {
    var onDone: (() -> Void)?

    let contentView = FlippedView()
    private let canvas: ScreenshotCanvasView
    private let scrollView = NSScrollView()
    private let tools = NSSegmentedControl(labels: ["Select", "Draw", "Arrow", "Text"], trackingMode: .selectOne, target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 12, target: nil, action: nil)
    private let widthLabel = NSTextField(labelWithString: "4 pt")
    private let undoButton = DeckButton(frame: .zero)
    private let redoButton = DeckButton(frame: .zero)
    private let clearButton = DeckButton(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "Draw freely — the canvas extends beyond the screenshot.")
    private let suggestedName: String

    init(image: NSImage, suggestedName: String) {
        canvas = ScreenshotCanvasView(image: image)
        self.suggestedName = suggestedName
        super.init()
        buildInterface()
        canvas.onStateChange = { [weak self] in self?.refreshControls() }
        refreshControls()
    }

    func prepareForDisplay() {
        DispatchQueue.main.async { [weak self] in self?.fitCanvas() }
    }

    private func buildInterface() {
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = DeckTheme.window.cgColor

        let toolbar = FlippedView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(hex: 0x0d1218).cgColor
        toolbar.layer?.borderColor = DeckTheme.line.cgColor
        toolbar.layer?.borderWidth = 1
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(toolbar)

        let toolbarStack = NSStackView()
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 9
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(toolbarStack)

        let backButton = makeActionButton("Back", symbol: "chevron.left", accent: false, action: #selector(done))
        toolbarStack.addArrangedSubview(backButton)

        let title = NSTextField(labelWithString: "Markup · \(suggestedName)")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = DeckTheme.secondaryText
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarStack.addArrangedSubview(title)

        tools.selectedSegment = ScreenshotTool.draw.rawValue
        tools.target = self
        tools.action = #selector(toolChanged(_:))
        tools.controlSize = .small
        tools.segmentStyle = .rounded
        tools.font = .systemFont(ofSize: 11, weight: .semibold)
        tools.setAccessibilityLabel("Markup tool")
        tools.translatesAutoresizingMaskIntoConstraints = false
        tools.widthAnchor.constraint(equalToConstant: 250).isActive = true
        tools.heightAnchor.constraint(equalToConstant: 34).isActive = true
        toolbarStack.addArrangedSubview(makeToolbarGroup([tools], spacing: 0))

        colorWell.color = canvas.annotationColor
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.toolTip = "Annotation color"
        colorWell.setAccessibilityLabel("Annotation color")
        if #available(macOS 13.0, *) { colorWell.colorWellStyle = .minimal }
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 34).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 32).isActive = true

        widthSlider.target = self
        widthSlider.action = #selector(widthChanged(_:))
        widthSlider.controlSize = .small
        widthSlider.isContinuous = false
        widthSlider.toolTip = "Line width"
        widthSlider.setAccessibilityLabel("Annotation line width")
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 72).isActive = true

        widthLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        widthLabel.textColor = DeckTheme.muted
        widthLabel.alignment = .right
        widthLabel.translatesAutoresizingMaskIntoConstraints = false
        widthLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true

        toolbarStack.addArrangedSubview(makeToolbarGroup([
            makeMicroLabel("COLOR"),
            colorWell,
            makeDivider(),
            makeMicroLabel("SIZE"),
            widthSlider,
            widthLabel
        ], spacing: 7))

        configureIconButton(undoButton, symbol: "arrow.uturn.backward", toolTip: "Undo")
        undoButton.target = self
        undoButton.action = #selector(undo)

        configureIconButton(redoButton, symbol: "arrow.uturn.forward", toolTip: "Redo")
        redoButton.target = self
        redoButton.action = #selector(redo)

        clearButton.title = "Clear"
        clearButton.font = .systemFont(ofSize: 11, weight: .semibold)
        clearButton.target = self
        clearButton.action = #selector(clear)
        styleButton(clearButton, fill: DeckTheme.card, border: DeckTheme.lineStrong, text: DeckTheme.secondaryText)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.widthAnchor.constraint(equalToConstant: 62).isActive = true
        clearButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        toolbarStack.addArrangedSubview(makeToolbarGroup([
            undoButton,
            redoButton,
            clearButton
        ], spacing: 5))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarStack.addArrangedSubview(spacer)

        let fitButton = makeActionButton("Fit", symbol: "arrow.up.left.and.arrow.down.right", accent: false, action: #selector(fitCanvas))
        let copyButton = makeActionButton("Copy", symbol: "doc.on.doc", accent: false, action: #selector(copyImage))
        toolbarStack.addArrangedSubview(makeToolbarGroup([fitButton, copyButton], spacing: 5))
        let downloadButton = makeActionButton("Download", symbol: "arrow.down.to.line", accent: true, action: #selector(downloadImage))
        toolbarStack.addArrangedSubview(downloadButton)

        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(hex: 0x10161e)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.2
        scrollView.maxMagnification = 3
        scrollView.documentView = canvas
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        let footer = FlippedView()
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(hex: 0x0d1218).cgColor
        footer.layer?.borderColor = DeckTheme.line.cgColor
        footer.layer?.borderWidth = 1
        footer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(footer)

        statusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.textColor = DeckTheme.muted
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(statusLabel)

        let exportHint = NSTextField(labelWithString: "Copy and Download trim to the artwork on the canvas background")
        exportHint.font = .systemFont(ofSize: 10.5, weight: .medium)
        exportHint.textColor = DeckTheme.dim
        exportHint.alignment = .right
        exportHint.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(exportHint)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 72),
            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 15),
            toolbarStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -15),
            toolbarStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 38),
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            exportHint.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            exportHint.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            exportHint.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 20)
        ])
    }

    @objc private func done() {
        onDone?()
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        guard let tool = ScreenshotTool(rawValue: sender.selectedSegment) else { return }
        canvas.setTool(tool)
        statusLabel.stringValue = statusMessage(for: tool)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.updateColor(sender.color)
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        canvas.updateLineWidth(CGFloat(sender.doubleValue))
        widthLabel.stringValue = "\(Int(sender.doubleValue.rounded())) pt"
    }

    @objc private func undo() { canvas.undoChange() }
    @objc private func redo() { canvas.redoChange() }
    @objc private func clear() { canvas.clearAnnotations() }

    @objc private func fitCanvas() {
        guard scrollView.contentSize.width > 0, scrollView.contentSize.height > 0 else { return }
        let padding: CGFloat = 36
        let imageArea = canvas.screenshotFrame.insetBy(dx: -padding, dy: -padding)
        let scale = min(
            (scrollView.contentSize.width - 28) / imageArea.width,
            (scrollView.contentSize.height - 28) / imageArea.height,
            1.25
        )
        let resolvedScale = max(scrollView.minMagnification, scale)
        scrollView.magnification = resolvedScale
        let visibleSize = CGSize(
            width: scrollView.contentSize.width / resolvedScale,
            height: scrollView.contentSize.height / resolvedScale
        )
        let desiredOrigin = CGPoint(
            x: canvas.screenshotFrame.midX - visibleSize.width / 2,
            y: canvas.screenshotFrame.midY - visibleSize.height / 2
        )
        let maximumOrigin = CGPoint(
            x: max(0, canvas.bounds.width - visibleSize.width),
            y: max(0, canvas.bounds.height - visibleSize.height)
        )
        scrollView.contentView.scroll(to: CGPoint(
            x: max(0, min(maximumOrigin.x, desiredOrigin.x)),
            y: max(0, min(maximumOrigin.y, desiredOrigin.y))
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        contentView.window?.makeFirstResponder(canvas)
    }

    @objc private func copyImage() {
        guard let image = canvas.exportImage(), let png = pngData(from: image) else {
            showExportError("The marked-up image could not be rendered.")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        statusLabel.stringValue = "Copied \(Int(image.size.width)) × \(Int(image.size.height)) image to the clipboard"
    }

    @objc private func downloadImage() {
        guard let image = canvas.exportImage(), let data = pngData(from: image) else {
            showExportError("The marked-up image could not be rendered.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(sanitizedFilename(suggestedName)) – markup.png"
        panel.title = "Download marked-up screenshot"
        guard let window = contentView.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self?.statusLabel.stringValue = "Saved \(url.lastPathComponent)"
            } catch {
                self?.showExportError(error.localizedDescription)
            }
        }
    }

    private func refreshControls() {
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
        clearButton.isEnabled = canvas.hasAnnotations
        if let selection = canvas.selectionStyle {
            colorWell.color = selection.color
            widthSlider.doubleValue = Double(selection.lineWidth)
            widthLabel.stringValue = "\(Int(selection.lineWidth.rounded())) pt"
            if selection.isText {
                statusLabel.stringValue = "Text selected · drag a handle to resize · the box keeps every line visible · double-click to edit"
            } else if selection.isArrow {
                statusLabel.stringValue = canvas.tool == .select
                    ? "Arrow selected · drag the origin, diamond curve handle, or point · drag the line to reposition"
                    : "Arrow added · choose Select to adjust its origin, curve, point, or position"
            } else {
                statusLabel.stringValue = "\(selection.kindTitle.capitalized) selected · change color or thickness above · drag to move"
            }
        } else {
            colorWell.color = canvas.annotationColor
            widthSlider.doubleValue = Double(canvas.annotationLineWidth)
            widthLabel.stringValue = "\(Int(canvas.annotationLineWidth.rounded())) pt"
            statusLabel.stringValue = statusMessage(for: canvas.tool)
        }
        if canvas.isEditingText {
            statusLabel.stringValue = "Editing text · Return adds a line · ⌘Return finishes · Esc cancels"
        }
    }

    private func statusMessage(for tool: ScreenshotTool) -> String {
        switch tool {
        case .select: return "Select markup to restyle, move, or resize text boxes · double-click text to edit"
        case .draw: return "Draw freely — the canvas extends beyond the screenshot"
        case .arrow: return "Drag from the point of interest toward your callout"
        case .text: return "Click anywhere to place a multiline text note"
        }
    }

    private func pngData(from image: NSImage) -> Data? {
        let bitmap = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { lhs, rhs in
                lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
            }
        return bitmap?.representation(using: .png, properties: [:])
    }

    private func sanitizedFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
        return value
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showExportError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = contentView.window { alert.beginSheetModal(for: window) }
    }

    private func makeToolbarGroup(_ views: [NSView], spacing: CGFloat) -> NSView {
        let group = NSStackView(views: views)
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = spacing
        group.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
        group.wantsLayer = true
        group.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
        group.layer?.borderColor = NSColor.white.withAlphaComponent(0.075).cgColor
        group.layer?.borderWidth = 1
        group.layer?.cornerRadius = 10
        return group
    }

    private func makeMicroLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .monospacedSystemFont(ofSize: 8.5, weight: .bold)
        label.textColor = DeckTheme.dim
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DeckTheme.lineStrong.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return divider
    }

    private func configureIconButton(_ button: DeckButton, symbol: String, toolTip: String) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        styleButton(button, fill: DeckTheme.card, border: DeckTheme.lineStrong, text: DeckTheme.secondaryText)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    private func makeActionButton(_ title: String, symbol: String, accent: Bool, action: Selector) -> NSButton {
        let button = DeckButton(frame: .zero)
        button.title = title
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = action
        button.toolTip = title
        styleButton(
            button,
            fill: accent ? DeckTheme.accent : DeckTheme.card,
            border: accent ? DeckTheme.accent : DeckTheme.lineStrong,
            text: accent ? NSColor(hex: 0x172206) : DeckTheme.secondaryText
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: title == "Download" ? 108 : title == "Copy" ? 78 : 68).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func styleButton(_ button: DeckButton, fill: NSColor, border: NSColor, text: NSColor) {
        button.isBordered = false
        button.focusRingType = .none
        button.alignment = .center
        button.contentTintColor = text
        button.baseFill = fill
        button.hoverFill = fill.blended(withFraction: 0.12, of: .white) ?? DeckTheme.hover
        button.pressedFill = fill.blended(withFraction: 0.10, of: .black) ?? fill
        button.stroke = border
        button.cornerRadius = 8
        button.contentPadding = 9
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .font: button.font ?? NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: text
        ])
        button.updateDeckAppearance()
    }
}
