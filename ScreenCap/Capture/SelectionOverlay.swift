import AppKit

enum SelectionMode {
    case area, window, record, pin

    var hint: String {
        switch self {
        case .pin: return "Drag to pin an area on top of everything  ·  Click a window to pin it  ·  Esc to cancel"
        case .area: return "Drag to select an area  ·  Click a window to capture it  ·  Esc to cancel"
        case .window: return "Click a window to capture it  ·  Drag to select an area  ·  Esc to cancel"
        case .record: return "Drag to select the recording area  ·  Click a window to record it  ·  Esc to cancel"
        }
    }
}

enum SelectionResult {
    case area(NSScreen, CGRect)
    case window(WindowInfo)
    case cancelled
}

/// Puts a translucent, click-through-proof overlay on every display and reports what the user picked.
/// Uses non-activating panels so the front app keeps focus and looks normal in the capture.
@MainActor
final class SelectionSession {
    let mode: SelectionMode
    private let completion: (SelectionResult) -> Void
    private var panels: [OverlayPanel] = []
    private(set) var windows: [WindowInfo] = []
    private var finished = false

    init(mode: SelectionMode, completion: @escaping (SelectionResult) -> Void) {
        self.mode = mode
        self.completion = completion
    }

    func begin() {
        windows = WindowEnumerator.onScreenWindows()
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen, session: self)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        let keyPanel = panels.first { $0.screen?.frame.contains(mouse) == true } ?? panels.first
        keyPanel?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
        panels.forEach { $0.contentView?.needsDisplay = true }
    }

    func window(at screenPoint: CGPoint) -> WindowInfo? {
        windows.first { $0.frame.contains(screenPoint) }
    }

    func refreshAll() {
        panels.forEach { $0.contentView?.needsDisplay = true }
    }

    func finish(_ result: SelectionResult) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        completion(result)
    }

    func cancel() { finish(.cancelled) }
}

final class OverlayPanel: NSPanel {
    private weak var session: SelectionSession?

    init(screen: NSScreen, session: SelectionSession) {
        self.session = session
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), screen: screen, session: session)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    private let screen: NSScreen
    private weak var session: SelectionSession?

    private var mouseLocation: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hoveredWindow: WindowInfo?

    init(frame: CGRect, screen: NSScreen, session: SelectionSession) {
        self.screen = screen
        self.session = session
        super.init(frame: frame)
        wantsLayer = true
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Coordinate helpers

    private func screenPoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x + screen.frame.minX, y: viewPoint.y + screen.frame.minY)
    }

    private func viewRect(fromScreen r: CGRect) -> CGRect {
        r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        mouseLocation = nil
        hoveredWindow = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        let p = location(of: event)
        mouseLocation = p
        hoveredWindow = dragStart == nil ? session?.window(at: screenPoint(p)) : nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragStart = location(of: event)
        selection = nil
        hoveredWindow = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = location(of: event)
        mouseLocation = p
        var rect = CGRect(corner: start, corner: p)
        if event.modifierFlags.contains(.shift) {
            // Shift constrains to a square.
            let side = max(rect.width, rect.height)
            rect = CGRect(x: p.x >= start.x ? start.x : start.x - side,
                          y: p.y >= start.y ? start.y : start.y - side,
                          width: side, height: side)
        }
        selection = rect.intersection(bounds).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let session else { return }
        if let sel = selection, sel.width >= 4, sel.height >= 4 {
            session.finish(.area(screen, viewRectToScreen(sel)))
            return
        }
        let p = screenPoint(location(of: event))
        if let w = session.window(at: p) {
            session.finish(.window(w))
        } else {
            // Clicked the bare desktop: capture the whole display.
            session.finish(.area(screen, screen.frame))
        }
    }

    private func viewRectToScreen(_ r: CGRect) -> CGRect {
        r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    override func rightMouseDown(with event: NSEvent) {
        session?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            session?.cancel()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dim = NSColor.black.withAlphaComponent(0.28)

        if let sel = selection {
            // Dim everything except the selection.
            let path = NSBezierPath(rect: bounds)
            path.appendRect(sel)
            path.windingRule = .evenOdd
            dim.setFill()
            path.fill()

            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            drawHandles(for: sel)
            drawLabel("\(Int(sel.width)) × \(Int(sel.height))", near: sel)
        } else if let w = hoveredWindow {
            dim.setFill()
            bounds.fill()
            let r = viewRect(fromScreen: w.frame).intersection(bounds)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            p.lineWidth = 2
            p.stroke()
            drawLabel("\(w.displayName)   \(Int(w.frame.width)) × \(Int(w.frame.height))", near: r, inside: true)
        } else {
            dim.setFill()
            bounds.fill()
            if let m = mouseLocation {
                NSColor.white.withAlphaComponent(0.55).setStroke()
                let cross = NSBezierPath()
                cross.move(to: CGPoint(x: m.x + 0.5, y: 0)); cross.line(to: CGPoint(x: m.x + 0.5, y: bounds.height))
                cross.move(to: CGPoint(x: 0, y: m.y + 0.5)); cross.line(to: CGPoint(x: bounds.width, y: m.y + 0.5))
                cross.lineWidth = 1
                cross.stroke()
                let sp = screenPoint(m)
                drawLabel("\(Int(sp.x)), \(Int(NSScreen.primaryHeight - sp.y))", at: CGPoint(x: m.x + 14, y: m.y - 30))
            }
        }

        drawHint(ctx)
    }

    private func drawHandles(for rect: CGRect) {
        let pts = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        NSColor.white.setFill()
        for p in pts {
            NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        }
    }

    private func labelAttributes() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
    }

    private func drawLabel(_ text: String, near rect: CGRect, inside: Bool = false) {
        let attr = NSAttributedString(string: text, attributes: labelAttributes())
        let size = attr.size()
        var origin = CGPoint(x: rect.maxX - size.width - 8, y: rect.minY - size.height - 14)
        if inside || origin.y < 8 { origin.y = rect.minY + 8 }
        origin.x = max(8, min(origin.x, bounds.width - size.width - 16))
        drawLabel(text, at: origin)
    }

    private func drawLabel(_ text: String, at origin: CGPoint) {
        let attr = NSAttributedString(string: text, attributes: labelAttributes())
        let size = attr.size()
        let pill = CGRect(x: origin.x, y: origin.y, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        attr.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 4))
    }

    private func drawHint(_ ctx: CGContext) {
        guard let session, dragStart == nil else { return }
        let attr = NSAttributedString(string: session.mode.hint, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = attr.size()
        let pill = CGRect(x: (bounds.width - size.width - 28) / 2, y: bounds.height - 80, width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
        attr.draw(at: CGPoint(x: pill.minX + 14, y: pill.minY + 7))
    }
}
