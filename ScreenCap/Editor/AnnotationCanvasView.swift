import AppKit
import Combine
import SwiftUI

/// AppKit canvas: displays the image scaled to fit and handles all drawing tools.
/// Coordinates: `isFlipped` so view space is y-down like the image; doc space = image pixels.
final class AnnotationCanvasView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let document: AnnotationDocument
    private var cancellables = Set<AnyCancellable>()

    /// View points per composite pixel.
    private var zoom: CGFloat = 1
    /// Top-left of the composite canvas in view coordinates.
    private var canvasOrigin: CGPoint = .zero
    /// Padding offset (composite pixels) between the canvas and the screenshot.
    private var imageOffset: CGPoint = .zero

    private var inProgress: Annotation?
    private var dragStartDoc: CGPoint?
    private var moveOriginal: Annotation?
    private var didPushMoveUndo = false

    private var textField: NSTextField?
    private var editingTextID: UUID?
    private var textOrigin: CGPoint = .zero

    init(document: AnnotationDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        document.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &cancellables)
        // Padding changes the composite size, so re-fit the zoom when the background style changes.
        document.$backgroundStyle
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.needsLayout = true }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        let margin: CGFloat = 24
        let avail = CGSize(width: max(bounds.width - margin * 2, 10), height: max(bounds.height - margin * 2, 10))
        let layout = document.compositeLayout
        let px = layout.canvasSize
        let fit = min(avail.width / px.width, avail.height / px.height)
        zoom = min(fit, 1 / document.pixelScale)
        let shown = CGSize(width: px.width * zoom, height: px.height * zoom)
        canvasOrigin = CGPoint(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2)
        imageOffset = layout.imageOffset
        repositionTextField()
        needsDisplay = true
    }

    // MARK: Coordinates

    /// View point → image pixel coordinates (padding removed).
    private func docPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (p.x - canvasOrigin.x) / zoom - imageOffset.x, y: (p.y - canvasOrigin.y) / zoom - imageOffset.y)
    }

    /// Image pixel coordinates → view point.
    private func viewPoint(_ doc: CGPoint) -> CGPoint {
        CGPoint(x: canvasOrigin.x + (doc.x + imageOffset.x) * zoom, y: canvasOrigin.y + (doc.y + imageOffset.y) * zoom)
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), document.pixelSize.width), y: min(max(p.y, 0), document.pixelSize.height))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let layout = document.compositeLayout
        let background = document.backgroundStyle
        let canvasRect = CGRect(origin: .zero, size: layout.canvasSize)

        ctx.saveGState()
        ctx.translateBy(x: canvasOrigin.x, y: canvasOrigin.y)
        ctx.scaleBy(x: zoom, y: zoom)

        // Canvas-only decoration: a soft shadow under the composite so it reads as a card on the dark view.
        // When there is no background the transparent padding is outlined instead.
        if background.kind != .none {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 24, color: CGColor(gray: 0, alpha: 0.5))
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(canvasRect)
            ctx.restoreGState()
        } else if background.padding > 0 {
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
            ctx.setLineWidth(1 / zoom)
            ctx.setLineDash(phase: 0, lengths: [6 / zoom, 4 / zoom])
            ctx.stroke(canvasRect.insetBy(dx: 0.5 / zoom, dy: 0.5 / zoom))
            ctx.restoreGState()
        }

        ctx.clip(to: canvasRect)
        var shown = document.annotations.filter { $0.id != editingTextID }
        if let a = inProgress { shown.append(a) }
        AnnotationRenderer.drawComposite(image: document.baseImage, annotations: shown, pixelated: document.pixelatedImage,
                                         background: background, layout: layout, pixelScale: document.pixelScale,
                                         shadowScale: zoom, in: ctx)
        ctx.restoreGState()

        if let sel = document.selected, sel.id != editingTextID {
            let b = AnnotationRenderer.bounds(of: sel, pixelScale: document.pixelScale)
            let vr = CGRect(origin: viewPoint(b.origin), size: CGSize(width: b.width * zoom, height: b.height * zoom)).insetBy(dx: -4, dy: -4)
            let path = NSBezierPath(roundedRect: vr, xRadius: 3, yRadius: 3)
            path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if textField != nil { commitText() }
        let p = clampToImage(docPoint(event))
        let s = document.pixelScale
        var style = document.style

        switch document.tool {
        case .select:
            let hit = document.annotations.last { AnnotationRenderer.hitTest($0, point: p, pixelScale: s) }
            document.selectedID = hit?.id
            if let hit {
                if event.clickCount == 2, case .text(let str, let origin) = hit.shape {
                    beginTextEditing(at: origin, existing: hit, text: str)
                    return
                }
                dragStartDoc = p
                moveOriginal = hit
                didPushMoveUndo = false
            }
        case .text:
            document.selectedID = nil
            beginTextEditing(at: p, existing: nil, text: "")
        case .number:
            document.selectedID = nil
            document.add(Annotation(shape: .number(document.nextNumber, center: p), style: style))
        case .arrow:
            inProgress = Annotation(shape: .arrow(from: p, to: p), style: style)
        case .line:
            inProgress = Annotation(shape: .line(from: p, to: p), style: style)
        case .rect:
            inProgress = Annotation(shape: .rect(CGRect(origin: p, size: .zero)), style: style)
        case .ellipse:
            inProgress = Annotation(shape: .ellipse(CGRect(origin: p, size: .zero)), style: style)
        case .pen:
            inProgress = Annotation(shape: .pen([p]), style: style)
        case .highlighter:
            style.color = NSColor.systemYellow
            inProgress = Annotation(shape: .highlighter([p]), style: style)
        case .blur:
            inProgress = Annotation(shape: .blur(CGRect(origin: p, size: .zero)), style: style)
        }
        if inProgress != nil {
            document.selectedID = nil
            dragStartDoc = p
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clampToImage(docPoint(event))
        guard let start = dragStartDoc else { return }

        if let original = moveOriginal {
            if !didPushMoveUndo { document.pushUndo(); didPushMoveUndo = true }
            document.replace(original.translated(by: CGPoint(x: p.x - start.x, y: p.y - start.y)))
            return
        }
        guard var a = inProgress else { return }
        let shift = event.modifierFlags.contains(.shift)
        switch a.shape {
        case .arrow: a.shape = .arrow(from: start, to: shift ? snapAngle(start, p) : p)
        case .line: a.shape = .line(from: start, to: shift ? snapAngle(start, p) : p)
        case .rect: a.shape = .rect(rect(start, p, square: shift))
        case .ellipse: a.shape = .ellipse(rect(start, p, square: shift))
        case .blur: a.shape = .blur(rect(start, p, square: shift))
        case .pen(var pts): pts.append(p); a.shape = .pen(pts)
        case .highlighter(var pts): pts.append(p); a.shape = .highlighter(pts)
        default: break
        }
        inProgress = a
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let a = inProgress {
            if a.isMeaningful {
                document.add(a)
                document.selectedID = nil
            }
            inProgress = nil
        }
        dragStartDoc = nil
        moveOriginal = nil
        needsDisplay = true
    }

    private func rect(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
        var r = CGRect(corner: a, corner: b)
        if square {
            let side = max(r.width, r.height)
            r = CGRect(x: b.x >= a.x ? a.x : a.x - side, y: b.y >= a.y ? a.y : a.y - side, width: side, height: side)
        }
        return r
    }

    private func snapAngle(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
        let len = a.distance(to: b)
        return CGPoint(x: a.x + cos(snapped) * len, y: a.y + sin(snapped) * len)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: // Esc
            if textField != nil { cancelText() } else { document.selectedID = nil }
            return
        case 51, 117: // Delete / Forward delete
            if document.selectedID != nil { document.removeSelected(); return }
        default: break
        }
        if flags.isEmpty || flags == .shift, let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = AnnotationTool.allCases.first(where: { $0.shortcut == ch }) {
            document.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    @objc func undo(_ sender: Any?) { document.undo() }
    @objc func redo(_ sender: Any?) { document.redo() }
    @objc func delete(_ sender: Any?) { document.removeSelected() }

    @objc func copy(_ sender: Any?) {
        if let img = document.render() { Clipboard.copy(image: img, pixelScale: document.pixelScale) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return document.canUndo
        case #selector(redo(_:)): return document.canRedo
        case #selector(delete(_:)): return document.selectedID != nil
        default: return true
        }
    }

    // MARK: Text editing

    private func beginTextEditing(at origin: CGPoint, existing: Annotation?, text: String) {
        textOrigin = origin
        editingTextID = existing?.id
        let field = NSTextField(frame: .zero)
        field.delegate = self
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.stringValue = text
        field.placeholderString = "Text"
        field.textColor = existing?.style.color ?? document.style.color
        field.font = NSFont.systemFont(ofSize: (existing?.style.fontSize ?? document.style.fontSize) * document.pixelScale * zoom, weight: .semibold)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        addSubview(field)
        textField = field
        repositionTextField()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    private func repositionTextField() {
        guard let field = textField else { return }
        let origin = viewPoint(textOrigin)
        let height = (field.font?.pointSize ?? 20) * 1.4
        field.frame = CGRect(x: origin.x - 2, y: origin.y - 2, width: max(60, bounds.width - origin.x), height: height)
    }

    private func commitText() {
        guard let field = textField else { return }
        let string = field.stringValue
        let existing = document.annotations.first { $0.id == editingTextID }
        field.removeFromSuperview()
        textField = nil
        editingTextID = nil
        window?.makeFirstResponder(self)

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if var existing {
            if trimmed.isEmpty {
                document.selectedID = existing.id
                document.removeSelected()
            } else if case .text(let old, let o) = existing.shape, old != string {
                document.pushUndo()
                existing.shape = .text(string, origin: o)
                document.replace(existing)
            }
        } else if !trimmed.isEmpty {
            document.add(Annotation(shape: .text(string, origin: textOrigin), style: document.style))
        }
        needsDisplay = true
    }

    private func cancelText() {
        textField?.removeFromSuperview()
        textField = nil
        editingTextID = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitText(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if textField != nil { commitText() }
    }
}

struct AnnotationCanvas: NSViewRepresentable {
    let document: AnnotationDocument

    func makeNSView(context: Context) -> AnnotationCanvasView {
        AnnotationCanvasView(document: document)
    }

    func updateNSView(_ nsView: AnnotationCanvasView, context: Context) {}
}
