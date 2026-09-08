import AppKit
import SwiftUI
import Combine

/// Keeps track of every floating "pinned" capture so the menu can list and close them.
@MainActor
final class PinController: ObservableObject {
    static let shared = PinController()

    @Published private(set) var pins: [PinnedPanel] = []

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
        let panel = PinnedPanel(item: item, frame: frame)
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.pins.removeAll { $0 === panel }
        }
        pins.append(panel)
        panel.present()
    }

    /// Hides every pin or brings them all back. Stub: filled in by the pin work stream.
    func toggleHidden() {
        NSLog("toggleHidden not implemented yet")
    }

    func closeAll() {
        for p in pins { p.close() }
        pins.removeAll()
    }

    private func fit(_ size: CGSize, into box: CGSize) -> CGSize {
        let s = min(1, min(box.width / size.width, box.height / size.height))
        return CGSize(width: size.width * s, height: size.height * s)
    }
}

/// A borderless, always-on-top, non-activating panel showing one capture.
/// Drag anywhere to move, resize from the edges (aspect locked), scroll to change opacity, Esc to close.
final class PinnedPanel: NSPanel {
    let item: CaptureItem
    let state = PinState()
    var onClose: (() -> Void)?

    init(item: CaptureItem, frame: CGRect) {
        self.item = item
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
        state.showOpacityBadge()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        onClose?()
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
}

/// Routes scroll / Esc to the panel; SwiftUI handles hover and buttons.
final class PinHostingView: NSHostingView<PinContentView> {
    private weak var panel: PinnedPanel?

    init(rootView: PinContentView, panel: PinnedPanel) {
        self.panel = panel
        super.init(rootView: rootView)
    }

    @MainActor required init(rootView: PinContentView) { fatalError() }
    @MainActor required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard let panel else { return }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        panel.setOpacity(panel.alphaValue + delta)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: panel?.close()                                 // Esc
        case 8 where event.modifierFlags.contains(.command):     // ⌘C
            panel?.copyImage()
        case 1 where event.modifierFlags.contains(.command):     // ⌘S
            panel?.saveImage()
        case 13 where event.modifierFlags.contains(.command):    // ⌘W
            panel?.close()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class PinState: ObservableObject {
    @Published var opacity: CGFloat = 1
    @Published var badgeVisible = false
    @Published var borderFlash = false
    private var badgeTask: Task<Void, Never>?

    func showOpacityBadge() {
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
    @State private var hovering = false

    private let radius: CGFloat = 8

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

            if state.badgeVisible {
                VStack {
                    HStack {
                        Spacer()
                        Text("\(Int((state.opacity * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.7)))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                    Spacer()
                }
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
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { panel.copyImage() }
            Button("Save") { panel.saveImage() }
            Button("Annotate") { panel.annotate() }
            Divider()
            Menu("Opacity") {
                ForEach([1.0, 0.8, 0.6, 0.4, 0.25], id: \.self) { o in
                    Button("\(Int(o * 100))%") { panel.setOpacity(o) }
                }
            }
            Divider()
            Button("Close") { panel.close() }
            Button("Close All Pins") { PinController.shared.closeAll() }
        }
        .help("Drag to move · Resize from edges · Scroll to change opacity · Esc to close")
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

    private var actionBar: some View {
        HStack(spacing: 2) {
            pinButton("doc.on.doc", "Copy (⌘C)") { panel.copyImage() }
            pinButton("square.and.arrow.down", "Save (⌘S)") { panel.saveImage() }
            pinButton("pencil.tip.crop.circle", "Annotate") { panel.annotate() }
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
