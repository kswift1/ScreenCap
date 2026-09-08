import AppKit
import SwiftUI

/// The CleanShot-style stack of thumbnails in the bottom-left corner. Cards auto-dismiss
/// unless hovered; drag them into other apps, use the hover buttons, or press a single key
/// while hovering (C copy, S save, ⇧S save as, E annotate, P pin, G GIF, O open, F Finder,
/// ⌫/Esc dismiss, ⌘⌫ dismiss all).
@MainActor
final class QuickAccessController: ObservableObject {
    static let shared = QuickAccessController()

    @Published private(set) var items: [CaptureItem] = []
    private var panel: QuickAccessPanel?
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    private var hovering: Set<UUID> = []
    /// The card currently under the mouse; single-key shortcuts act on it.
    private weak var keyboardTarget: CaptureItem?

    func add(_ item: CaptureItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        if items.count > 5 { remove(items[0], animated: false) }
        scheduleDismiss(item)
        showPanel()
    }

    func remove(_ item: CaptureItem, animated: Bool = true) {
        dismissTasks[item.id]?.cancel()
        dismissTasks[item.id] = nil
        hovering.remove(item.id)
        withAnimation(animated ? .easeOut(duration: 0.18) : nil) {
            items.removeAll { $0.id == item.id }
        }
        layoutPanel()
        if keyboardTarget === item {
            keyboardTarget = nil
            releaseKeyboard()
        }
        hidePanelWhenEmpty()
    }

    /// Dismisses every card at once (⌘⌫ or the context menu).
    func removeAll() {
        dismissTasks.values.forEach { $0.cancel() }
        dismissTasks.removeAll()
        hovering.removeAll()
        keyboardTarget = nil
        withAnimation(.easeOut(duration: 0.18)) { items.removeAll() }
        hidePanelWhenEmpty()
    }

    /// Hides the panel once the last card has faded out. Ordering out also drops key status.
    private func hidePanelWhenEmpty() {
        guard items.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.items.isEmpty else { return }
            self.panel?.orderOut(nil)
        }
    }

    func showLast() {
        guard let last = CaptureCoordinator.shared.history.last else { return }
        if items.contains(where: { $0.id == last.id }) {
            scheduleDismiss(last)
        } else {
            add(last)
        }
    }

    func setHovering(_ item: CaptureItem, _ isHovering: Bool) {
        if isHovering {
            hovering.insert(item.id)
            dismissTasks[item.id]?.cancel()
            keyboardTarget = item
            acquireKeyboard()
        } else {
            hovering.remove(item.id)
            scheduleDismiss(item)
            if keyboardTarget === item {
                keyboardTarget = nil
                releaseKeyboard()
            }
        }
    }

    // MARK: Keyboard

    /// Routes keyboard input to the panel while a card is hovered. A `.nonactivatingPanel` may
    /// become key without activating the app, so the front app keeps looking active while our
    /// hosting view receives `keyDown`.
    private func acquireKeyboard() {
        guard let panel, panel.isVisible else { return }
        if !panel.isKeyWindow { panel.makeKey() }
        if let content = panel.contentView, panel.firstResponder !== content {
            panel.makeFirstResponder(content)
        }
    }

    /// Hands keyboard focus back to the front app when the mouse leaves. `resignKey()` is not meant
    /// to be called directly and `NSApp.activate` is off-limits here, so we briefly order the panel
    /// out — which makes it resign key — and immediately re-order it front without key status.
    /// Both calls land in the same run-loop turn, so nothing visibly flickers.
    private func releaseKeyboard() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        if !items.isEmpty { panel.orderFrontRegardless() }
    }

    /// Handles a key press from the panel. Returns `false` for keys we don't own so the
    /// hosting view can pass them along instead of swallowing them.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let isDelete = event.keyCode == 51 || event.keyCode == 117   // ⌫ / ⌦
        if isDelete && mods == .command {                            // ⌘⌫
            removeAll()
            return true
        }
        guard let item = keyboardTarget, items.contains(where: { $0.id == item.id }), !item.isBusy else {
            return false
        }
        if (isDelete || event.keyCode == 53) && mods.isEmpty {       // ⌫ / ⌦ / Esc
            remove(item)
            return true
        }
        // Letters: plain or ⌘-prefixed both work; ⇧ picks the alternate (⇧S = Save As…).
        guard mods.subtracting([.shift, .command]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = mods.contains(.shift)
        switch key {
        case "c" where !shift: copy(item)
        case "s" where !shift: save(item)
        case "s" where shift: saveAs(item)
        case "e" where !shift && item.isImage: annotate(item)
        case "p" where !shift && item.isImage: pin(item)
        case "g" where !shift && item.isVideo: convertToGIF(item)
        case "o" where !shift: openExternally(item)
        case "f" where !shift: revealInFinder(item)
        default: return false
        }
        return true
    }

    private func scheduleDismiss(_ item: CaptureItem) {
        dismissTasks[item.id]?.cancel()
        let seconds = Preferences.quickAccessDuration
        guard seconds > 0 else { return }
        dismissTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if self.hovering.contains(item.id) || item.isBusy {
                self.scheduleDismiss(item)
            } else {
                self.remove(item)
            }
        }
    }

    // MARK: Actions

    func copy(_ item: CaptureItem) {
        if let image = item.image {
            Clipboard.copy(image: image, pixelScale: item.pixelScale)
        } else {
            Clipboard.copy(fileURL: item.url)
        }
        remove(item)
    }

    func save(_ item: CaptureItem) {
        do {
            try FileStore.saveToUserFolder(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.remove(item) }
        } catch {
            ErrorPresenter.show(error, title: "Couldn't save")
        }
    }

    func saveAs(_ item: CaptureItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.directoryURL = Preferences.saveDirectory
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: item.url, to: dest)
                item.savedURL = dest
                self?.remove(item)
            } catch {
                ErrorPresenter.show(error, title: "Couldn't save")
            }
        }
    }

    func annotate(_ item: CaptureItem) {
        guard let image = item.image else { return }
        remove(item)
        EditorWindowController.open(image: image, pixelScale: item.pixelScale, sourceItem: item)
    }

    func pin(_ item: CaptureItem) {
        guard item.isImage else { return }
        remove(item)
        PinController.shared.pin(item, at: item.sourceRect)
    }

    func openExternally(_ item: CaptureItem) {
        NSWorkspace.shared.open(item.savedURL ?? item.url)
    }

    func revealInFinder(_ item: CaptureItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.savedURL ?? item.url])
    }

    func convertToGIF(_ item: CaptureItem) {
        guard item.isVideo, !item.isBusy else { return }
        item.isBusy = true
        let source = item.url
        let gifURL = source.deletingPathExtension().appendingPathExtension("gif")
        let fps = Preferences.gifFPS
        let maxWidth = Preferences.gifMaxWidth
        Task {
            do {
                try await GIFExporter.export(video: source, to: gifURL, fps: fps, maxWidth: maxWidth, progress: { _ in })
                item.isBusy = false
                let gif = CaptureItem(gifURL: gifURL, pixelScale: item.pixelScale)
                CaptureCoordinator.shared.add(gifItem: gif)
                if Preferences.copyToClipboard { Clipboard.copy(fileURL: gifURL) }
            } catch {
                item.isBusy = false
                ErrorPresenter.show(error, title: "GIF conversion failed")
            }
        }
    }

    // MARK: Panel

    private func showPanel() {
        if panel == nil {
            let p = QuickAccessPanel(contentRect: CGRect(x: 0, y: 0, width: 260, height: 100),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            // Above pins (.floating) but not status-bar level: status-bar-level windows disappear on full-screen Spaces.
            p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let hosting = QuickAccessHostingView(rootView: QuickAccessView(controller: self), controller: self)
            hosting.sizingOptions = []
            // Assign before installing the content view: SwiftUI can report its size synchronously
            // during that install, and updatePanelSize needs `panel` to be set by then.
            panel = p
            p.contentView = hosting
        }
        guard let panel else { return }
        if !panel.isVisible {
            let screen = NSScreen.underMouse
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 16, y: screen.visibleFrame.minY + 16))
        }
        panel.orderFrontRegardless()
        layoutPanel()
    }

    /// Sizes the panel from the cards it holds (width + stacked heights). The SwiftUI preference
    /// path also calls updatePanelSize, but this deterministic path never depends on layout timing.
    func layoutPanel() {
        guard !items.isEmpty else { return }
        let pad = QuickAccessCard.stackPadding
        let heights = items.map { QuickAccessCard.thumbSize(for: $0).height }
        let height = heights.reduce(0, +) + CGFloat(max(items.count - 1, 0)) * QuickAccessCard.cardSpacing + pad * 2
        updatePanelSize(CGSize(width: QuickAccessCard.cardWidth + pad * 2, height: height))
    }

    /// Called by the SwiftUI root whenever its natural size changes; the panel grows upward from its bottom-left corner.
    func updatePanelSize(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let origin = panel.frame.origin
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// Borderless non-activating panel that may still become key, so hovered cards can take single-key
/// shortcuts without ScreenCap ever becoming the active app.
final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Routes key presses to the controller; SwiftUI handles hover, buttons, and drag.
final class QuickAccessHostingView: NSHostingView<QuickAccessView> {
    private unowned let controller: QuickAccessController

    init(rootView: QuickAccessView, controller: QuickAccessController) {
        self.controller = controller
        super.init(rootView: rootView)
    }

    @MainActor required init(rootView: QuickAccessView) { fatalError() }
    @MainActor required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !controller.handleKey(event) { super.keyDown(with: event) }
    }

    /// ⌘-shortcuts (⌘⌫, ⌘C, ⌘S) arrive here before the main menu gets a chance to claim them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        controller.handleKey(event) || super.performKeyEquivalent(with: event)
    }
}
