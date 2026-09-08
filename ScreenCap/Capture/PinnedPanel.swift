import AppKit
import SwiftUI
import Combine

/// Keeps track of every floating "pinned" capture so the menu can list, hide, unlock and close them.
@MainActor
final class PinController: ObservableObject {
    static let shared = PinController()

    /// What we remember about a pin after it closes so it can be brought back.
    struct ClosedPin {
        let item: CaptureItem
        let frame: CGRect
        let originalSize: CGSize
    }

    @Published private(set) var pins: [PinnedPanel] = []
    /// True while every pin is ordered out by `toggleHidden()`.
    @Published private(set) var isHidden = false
    /// The most recently closed pin, restored by `reopenLastClosed()`.
    @Published private(set) var lastClosed: ClosedPin?

    var lockedPins: [PinnedPanel] { pins.filter(\.isLocked) }

    /// Shows `item` floating at `rect` (Cocoa screen coordinates). Falls back to the centre of the
    /// current screen when we don't know where it came from.
    func pin(_ item: CaptureItem, at rect: CGRect?) {
        guard let image = item.image else { return }
        let logical = CGSize(width: CGFloat(image.width) / item.pixelScale, height: CGFloat(image.height) / item.pixelScale)
        var frame: CGRect
        if let rect, rect.width > 10, rect.height > 10 {
            frame = CGRect(origin: rect.origin, size: logical)
        } else {
            let screen = NSScreen.underMouse.visibleFrame
            let size = fit(logical, into: CGSize(width: screen.width * 0.6, height: screen.height * 0.6))
            frame = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        }
        install(PinnedPanel(item: item, frame: frame))
    }

    /// Recreates the last pin that was closed, at the frame and zoom it had when it went away.
    func reopenLastClosed() {
        guard let closed = lastClosed else { return }
        lastClosed = nil
        install(PinnedPanel(item: closed.item, frame: closed.frame, originalSize: closed.originalSize))
    }

    /// Hides every pin (they stay in `pins` at their frames) or brings them all back.
    func toggleHidden() {
        guard !pins.isEmpty else { return }
        if isHidden {
            showAll()
        } else {
            for p in pins { p.orderOut(nil) }
            isHidden = true
        }
    }

    /// Orders every pin back on screen if they were hidden.
    func showAll() {
        for p in pins { p.orderFrontRegardless() }
        isHidden = false
    }

    /// Clears the lock on every pin so they can be moved and clicked again.
    func unlockAll() {
        for p in pins where p.isLocked { p.setLocked(false) }
    }

    /// Shows the pins if hidden and puts `panel` above the others.
    func bringToFront(_ panel: PinnedPanel) {
        if isHidden { showAll() }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func closeAll() {
        for p in pins { p.close() }
        pins.removeAll()
        isHidden = false
    }

    /// Registers a new panel, hooks up its close handler and shows it.
    private func install(_ panel: PinnedPanel) {
        panel.onClose = { [weak self, weak panel] frame in
            guard let self, let panel else { return }
            self.lastClosed = ClosedPin(item: panel.item, frame: frame, originalSize: panel.originalSize)
            self.pins.removeAll { $0 === panel }
            if self.pins.isEmpty { self.isHidden = false }
        }
        if isHidden { showAll() }
        pins.append(panel)
        panel.present()
    }

    private func fit(_ size: CGSize, into box: CGSize) -> CGSize {
        let s = min(1, min(box.width / size.width, box.height / size.height))
        return CGSize(width: size.width * s, height: size.height * s)
    }
}

/// A borderless, always-on-top, non-activating panel showing one capture.
/// Drag anywhere to move, resize from the edges (aspect locked), scroll to change opacity,
/// ⌘-scroll / pinch to zoom, double-click to reset zoom, arrows to nudge, ⌘L to lock, Esc to close.
final class PinnedPanel: NSPanel {
    let item: CaptureItem
    /// The logical size the capture was pinned at; zoom is measured relative to this.
    let originalSize: CGSize
    let state = PinState()
    /// Called once when the panel closes, with the frame it had at that moment.
    var onClose: ((CGRect) -> Void)?

    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 4

    var isLocked: Bool { state.isLocked }
    /// Current scale relative to `originalSize` (1 = 100%).
    var zoom: CGFloat { frame.width / originalSize.width }

    init(item: CaptureItem, frame: CGRect, originalSize: CGSize? = nil) {
        self.item = item
        self.originalSize = originalSize ?? frame.size
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        minSize = CGSize(width: 80, height: 60)
        contentAspectRatio = frame.size
        animationBehavior = .utilityWindow

        let hosting = PinHostingView(rootView: PinContentView(panel: self, state: state), panel: self)
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
        state.flashBorder()
    }

    func setOpacity(_ value: CGFloat) {
        let clamped = min(1, max(0.15, value))
        state.opacity = clamped
        alphaValue = clamped
        state.showBadge(symbol: "circle.lefthalf.filled", text: percentText(clamped))
    }

    // MARK: Zoom

    /// Scales the window to `scale` × `originalSize` around its centre, clamped to 25%–400%
    /// (and never below `minSize`).
    func setZoom(_ scale: CGFloat) {
        let lower = max(Self.minZoom, minSize.width / originalSize.width, minSize.height / originalSize.height)
        let s = min(Self.maxZoom, max(lower, scale))
        let size = CGSize(width: originalSize.width * s, height: originalSize.height * s)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        setFrame(CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                        width: size.width, height: size.height), display: true)
        state.showBadge(symbol: "plus.magnifyingglass", text: percentText(s))
    }

    /// Back to 100% at the original size, keeping the centre where it is.
    func resetZoom() { setZoom(1) }

    // MARK: Lock

    /// Locked pins can't be moved or resized and let clicks fall through to whatever is behind.
    func setLocked(_ locked: Bool) {
        state.isLocked = locked
        state.hovering = false
        ignoresMouseEvents = locked
        isMovableByWindowBackground = !locked
        if locked { styleMask.remove(.resizable) } else { styleMask.insert(.resizable) }
    }

    func toggleLocked() { setLocked(!isLocked) }

    // MARK: Nudge

    /// Moves the panel by `dx`/`dy` points unless it is locked.
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard !isLocked else { return }
        setFrameOrigin(CGPoint(x: frame.origin.x + dx, y: frame.origin.y + dy))
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        let lastFrame = frame
        super.close()
        onClose?(lastFrame)
        onClose = nil
    }

    // MARK: Actions

    func copyImage() {
        guard let image = item.image else { return }
        Clipboard.copy(image: image, pixelScale: item.pixelScale)
        state.flashBorder()
    }

    func saveImage() {
        do {
            try FileStore.saveToUserFolder(item)
            state.flashBorder()
        } catch {
            ErrorPresenter.show(error, title: "Couldn't save")
        }
    }

    func annotate() {
        guard let image = item.image else { return }
        EditorWindowController.open(image: image, pixelScale: item.pixelScale, sourceItem: item)
    }

    private func percentText(_ value: CGFloat) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Routes scroll / pinch / keys to the panel; SwiftUI handles hover and buttons.
final class PinHostingView: NSHostingView<PinContentView> {
    private weak var panel: PinnedPanel?

    init(rootView: PinContentView, panel: PinnedPanel) {
        self.panel = panel
        super.init(rootView: rootView)
    }

    @MainActor required init(rootView: PinContentView) { fatalError() }
    @MainActor required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// Plain scroll changes opacity; ⌘-scroll zooms.
    override func scrollWheel(with event: NSEvent) {
        guard let panel else { return }
        if event.modifierFlags.contains(.command) {
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.005 : 0.05)
            panel.setZoom(panel.zoom * (1 + delta))
        } else {
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
            panel.setOpacity(panel.alphaValue + delta)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let panel else { return }
        panel.setZoom(panel.zoom * (1 + event.magnification))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            panel?.resetZoom()
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: panel?.close()                                 // Esc
        case 8 where cmd: panel?.copyImage()                    // ⌘C
        case 1 where cmd: panel?.saveImage()                    // ⌘S
        case 13 where cmd: panel?.close()                       // ⌘W
        case 37 where cmd: panel?.toggleLocked()                // ⌘L
        case 123: panel?.nudge(dx: -step, dy: 0)                // ←
        case 124: panel?.nudge(dx: step, dy: 0)                 // →
        case 125: panel?.nudge(dx: 0, dy: -step)                // ↓
        case 126: panel?.nudge(dx: 0, dy: step)                 // ↑
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class PinState: ObservableObject {
    @Published var opacity: CGFloat = 1
    @Published var isLocked = false
    @Published var hovering = false
    @Published var badgeVisible = false
    @Published var badgeSymbol = "circle.lefthalf.filled"
    @Published var badgeText = "100%"
    @Published var borderFlash = false
    private var badgeTask: Task<Void, Never>?

    /// Shows a transient badge (opacity or zoom) in the corner for a moment.
    func showBadge(symbol: String, text: String) {
        badgeSymbol = symbol
        badgeText = text
        badgeVisible = true
        badgeTask?.cancel()
        badgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            self?.badgeVisible = false
        }
    }

    func flashBorder() {
        borderFlash = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            self?.borderFlash = false
        }
    }
}

struct PinContentView: View {
    unowned let panel: PinnedPanel
    @ObservedObject var state: PinState

    private let radius: CGFloat = 8
    private var hovering: Bool { state.hovering && !state.isLocked }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = panel.item.image {
                Image(nsImage: image.nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }

            if hovering {
                closeButton.padding(6)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        actionBar
                        Spacer()
                    }
                    .padding(.bottom, 8)
                }
            }

            VStack {
                HStack(spacing: 4) {
                    Spacer()
                    if state.badgeVisible { transientBadge }
                    if state.isLocked { lockBadge }
                }
                .padding(8)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(state.borderFlash ? Color.accentColor : Color.white.opacity(hovering ? 0.6 : 0.25),
                        lineWidth: state.borderFlash ? 3 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: state.borderFlash)
        .onHover { state.hovering = $0 }
        .contextMenu {
            Button("Copy") { panel.copyImage() }
            Button("Save") { panel.saveImage() }
            Button("Annotate") { panel.annotate() }
            Divider()
            Button(state.isLocked ? "Unlock" : "Lock") { panel.toggleLocked() }
            Menu("Opacity") {
                ForEach([1.0, 0.8, 0.6, 0.4, 0.25], id: \.self) { o in
                    Button("\(Int(o * 100))%") { panel.setOpacity(o) }
                }
            }
            Menu("Zoom") {
                ForEach([0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { z in
                    Button("\(Int(z * 100))%") { panel.setZoom(z) }
                }
            }
            Divider()
            Button("Close") { panel.close() }
            Button("Close All Pins") { PinController.shared.closeAll() }
        }
        .help("Drag to move · Resize from edges · Scroll for opacity · ⌘-scroll or pinch to zoom · Double-click resets zoom · Arrows nudge · ⌘L locks · Esc to close")
    }

    private var closeButton: some View {
        Button { panel.close() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")
    }

    /// Opacity / zoom readout shown briefly after a change.
    private var transientBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: state.badgeSymbol)
                .font(.system(size: 10, weight: .semibold))
            Text(state.badgeText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.7)))
        .foregroundStyle(.white)
    }

    /// Persistent marker for a locked (click-through) pin.
    private var lockBadge: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 10, weight: .semibold))
            .padding(5)
            .background(Circle().fill(.black.opacity(0.7)))
            .foregroundStyle(.white)
            .help("Locked — unlock from the menu bar (Pins) or ⌘L")
    }

    private var actionBar: some View {
        HStack(spacing: 2) {
            pinButton("doc.on.doc", "Copy (⌘C)") { panel.copyImage() }
            pinButton("square.and.arrow.down", "Save (⌘S)") { panel.saveImage() }
            pinButton("pencil.tip.crop.circle", "Annotate") { panel.annotate() }
            pinButton("lock", "Lock (⌘L)") { panel.setLocked(true) }
        }
        .padding(3)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(.white.opacity(0.15)))
    }

    private func pinButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
