import AppKit

enum SelectionMode: CaseIterable {
    case area, window, fullscreen, pin, record, ocr, scroll

    var hint: String {
        switch self {
        case .ocr: return "Drag over text to copy it  ·  Click a window to read all of it  ·  Esc to cancel"
        case .pin: return "Drag to pin an area on top of everything  ·  Click a window to pin it  ·  Esc to cancel"
        case .area: return "Drag to select an area  ·  Click a window to capture it  ·  Esc to cancel"
        case .window: return "Click a window to capture it  ·  Drag to select an area  ·  Esc to cancel"
        case .fullscreen: return "Click to capture the whole display under the mouse  ·  Esc to cancel"
        case .record: return "Drag to select the recording area  ·  Click a window to record it  ·  Esc to cancel"
        case .scroll: return "Drag over the scrollable area to capture  ·  Click a window to capture all of it  ·  Esc to cancel"
        }
    }

    // MARK: All-in-One toolbar metadata

    /// Left-to-right order of the buttons in the All-in-One mode toolbar.
    static let toolbarOrder: [SelectionMode] = [.area, .window, .fullscreen, .pin, .record, .ocr, .scroll]

    var title: String {
        switch self {
        case .area: return "Area"
        case .window: return "Window"
        case .fullscreen: return "Fullscreen"
        case .pin: return "Pin"
        case .record: return "Record"
        case .ocr: return "Text"
        case .scroll: return "Scroll"
        }
    }

    var symbolName: String {
        switch self {
        case .area: return "crop"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        case .pin: return "pin"
        case .record: return "record.circle"
        case .ocr: return "text.viewfinder"
        case .scroll: return "arrow.up.and.down.text.horizontal"
        }
    }

    /// Letter shortcut that selects this mode while the All-in-One overlay is up.
    var letterKey: Character {
        switch self {
        case .area: return "a"
        case .window: return "w"
        case .fullscreen: return "f"
        case .pin: return "p"
        case .record: return "r"
        case .ocr: return "t"
        case .scroll: return "s"
        }
    }

    /// Digit shortcut (1–7) matching the toolbar position.
    var digitKey: Character {
        Character(String(Self.toolbarOrder.firstIndex(of: self)! + 1))
    }

    var keyHint: String { "\(letterKey.uppercased()) · \(digitKey)" }

    /// Mode for a typed key (letter or digit), or nil if the key isn't a mode shortcut.
    static func mode(forKey key: Character) -> SelectionMode? {
        let k = key.lowercased().first ?? key
        return toolbarOrder.first { $0.letterKey == k || $0.digitKey == k }
    }
}

enum SelectionResult {
    case area(NSScreen, CGRect)
    case window(WindowInfo)
    case cancelled
}

/// Puts a translucent, click-through-proof overlay on every display and reports what the user picked.
/// Uses non-activating panels so the front app keeps focus and looks normal in the capture.
/// With `allowsModeSwitch` (All-in-One) the overlay also shows a mode toolbar; the completion
/// receives the mode that was active when the selection was made.
@MainActor
final class SelectionSession {
    private(set) var mode: SelectionMode
    let allowsModeSwitch: Bool
    private let completion: (SelectionResult, SelectionMode) -> Void
    private var panels: [OverlayPanel] = []
    private(set) var windows: [WindowInfo] = []
    private var finished = false

    init(mode: SelectionMode, allowsModeSwitch: Bool = false, completion: @escaping (SelectionResult, SelectionMode) -> Void) {
        self.mode = mode
        self.allowsModeSwitch = allowsModeSwitch
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

    /// Changes the active mode (All-in-One only) and redraws every display's overlay.
    func switchMode(_ newMode: SelectionMode) {
        guard allowsModeSwitch, newMode != mode else { return }
        mode = newMode
        refreshAll()
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
        completion(result, mode)
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
    private var hoveredToolbarMode: SelectionMode?
    private var symbolCache: [String: NSImage] = [:]

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

    private var mode: SelectionMode { session?.mode ?? .area }

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
        hoveredToolbarMode = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = location(of: event)
        mouseLocation = p
        hoveredToolbarMode = toolbarMode(at: p)
        let overToolbar = showsToolbar && toolbarPillRect().contains(p)
        (overToolbar ? NSCursor.arrow : NSCursor.crosshair).set()
        hoveredWindow = (dragStart == nil && !overToolbar && mode != .fullscreen) ? session?.window(at: screenPoint(p)) : nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let p = location(of: event)
        if showsToolbar, toolbarPillRect().contains(p) {
            // Toolbar clicks switch mode and never start a selection.
            if let m = toolbarMode(at: p) { session?.switchMode(m) }
            needsDisplay = true
            return
        }
        dragStart = p
        selection = nil
        hoveredWindow = nil
        hoveredToolbarMode = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, mode != .fullscreen else { return }
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
        // A mouseUp without a matching dragStart came from a toolbar click; ignore it.
        guard let session, dragStart != nil else { return }
        defer { dragStart = nil }
        if mode == .fullscreen {
            session.finish(.area(screen, screen.frame))
            return
        }
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
            return
        }
        if let session, session.allowsModeSwitch, dragStart == nil,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let key = event.charactersIgnoringModifiers?.first,
           let m = SelectionMode.mode(forKey: key) {
            session.switchMode(m)
            refreshHover()
            return
        }
        super.keyDown(with: event)
    }

    /// Re-evaluates window hover after a mode change so Fullscreen drops the outline immediately.
    private func refreshHover() {
        guard let p = mouseLocation else { return }
        let overToolbar = showsToolbar && toolbarPillRect().contains(p)
        hoveredWindow = (!overToolbar && mode != .fullscreen) ? session?.window(at: screenPoint(p)) : nil
        needsDisplay = true
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
        } else {
            dim.setFill()
            bounds.fill()

            if let w = hoveredWindow {
                // Subtle outline only: no fill, so a hovered full-screen app doesn't tint the whole display.
                let r = viewRect(fromScreen: w.frame).intersection(bounds).insetBy(dx: 1, dy: 1)
                let outline = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
                outline.lineWidth = 1.5
                NSColor.white.withAlphaComponent(0.85).setStroke()
                outline.stroke()
                drawLabel("\(w.displayName)   \(Int(w.frame.width)) × \(Int(w.frame.height))", near: r, inside: true)
            }

            let overToolbar = showsToolbar && mouseLocation.map { toolbarPillRect().contains($0) } == true
            if let m = mouseLocation, !overToolbar, mode != .fullscreen {
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
        if showsToolbar { drawToolbar() }
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

    // MARK: All-in-One mode toolbar

    private enum Toolbar {
        static let buttonSize = CGSize(width: 74, height: 58)
        static let spacing: CGFloat = 4
        static let padding: CGFloat = 8
        static let bottomMargin: CGFloat = 40
    }

    /// The toolbar lives on the display the mouse is on, and hides while dragging.
    private var showsToolbar: Bool {
        guard let session, session.allowsModeSwitch, dragStart == nil else { return false }
        return screen.frame.contains(NSEvent.mouseLocation)
    }

    private func toolbarPillRect() -> CGRect {
        let count = CGFloat(SelectionMode.toolbarOrder.count)
        let width = count * Toolbar.buttonSize.width + (count - 1) * Toolbar.spacing + Toolbar.padding * 2
        let height = Toolbar.buttonSize.height + Toolbar.padding * 2
        return CGRect(x: ((bounds.width - width) / 2).rounded(), y: Toolbar.bottomMargin, width: width, height: height)
    }

    private func toolbarButtonRect(at index: Int) -> CGRect {
        let pill = toolbarPillRect()
        let x = pill.minX + Toolbar.padding + CGFloat(index) * (Toolbar.buttonSize.width + Toolbar.spacing)
        return CGRect(origin: CGPoint(x: x, y: pill.minY + Toolbar.padding), size: Toolbar.buttonSize)
    }

    /// Mode whose toolbar button contains the view point, if the toolbar is visible.
    private func toolbarMode(at p: CGPoint) -> SelectionMode? {
        guard showsToolbar else { return nil }
        for (i, m) in SelectionMode.toolbarOrder.enumerated() where toolbarButtonRect(at: i).contains(p) {
            return m
        }
        return nil
    }

    private func drawToolbar() {
        let pill = toolbarPillRect()
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 14, yRadius: 14).fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let edge = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        edge.lineWidth = 1
        edge.stroke()

        for (i, m) in SelectionMode.toolbarOrder.enumerated() {
            drawToolbarButton(m, in: toolbarButtonRect(at: i), active: m == mode, hovered: m == hoveredToolbarMode)
        }
    }

    private func drawToolbarButton(_ m: SelectionMode, in rect: CGRect, active: Bool, hovered: Bool) {
        if active || hovered {
            NSColor.white.withAlphaComponent(active ? 0.22 : 0.09).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        }
        let tint: NSColor = active ? .white : NSColor.white.withAlphaComponent(0.72)

        let icon = symbolImage(m.symbolName, tint: tint)
        let iconRect = CGRect(x: rect.midX - icon.size.width / 2, y: rect.maxY - 7 - icon.size.height,
                              width: icon.size.width, height: icon.size.height)
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        let title = NSAttributedString(string: m.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: active ? .semibold : .medium),
            .foregroundColor: tint,
        ])
        title.draw(at: CGPoint(x: rect.midX - title.size().width / 2, y: rect.minY + 16))

        let hint = NSAttributedString(string: m.keyHint, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(active ? 0.7 : 0.45),
        ])
        hint.draw(at: CGPoint(x: rect.midX - hint.size().width / 2, y: rect.minY + 4))
    }

    /// Tinted SF Symbol, cached per name + colour because draw() runs on every mouse move.
    private func symbolImage(_ name: String, tint: NSColor) -> NSImage {
        let key = "\(name)|\(tint.alphaComponent)"
        if let cached = symbolCache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            ?? NSImage(size: CGSize(width: 18, height: 18))
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        symbolCache[key] = tinted
        return tinted
    }
}
