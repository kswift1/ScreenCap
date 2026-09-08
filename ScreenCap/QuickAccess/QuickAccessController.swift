import AppKit
import SwiftUI

/// The CleanShot-style stack of thumbnails in the bottom-left corner. Cards auto-dismiss
/// unless hovered; drag them into other apps, or use the hover buttons.
@MainActor
final class QuickAccessController: ObservableObject {
    static let shared = QuickAccessController()

    @Published private(set) var items: [CaptureItem] = []
    private var panel: NSPanel?
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    private var hovering: Set<UUID> = []

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
        if items.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.items.isEmpty else { return }
                self.panel?.orderOut(nil)
            }
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
        } else {
            hovering.remove(item.id)
            scheduleDismiss(item)
        }
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
            let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 260, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let hosting = NSHostingView(rootView: QuickAccessView(controller: self))
            hosting.sizingOptions = []
            p.contentView = hosting
            panel = p
        }
        guard let panel else { return }
        if !panel.isVisible {
            let screen = NSScreen.underMouse
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 16, y: screen.visibleFrame.minY + 16))
        }
        panel.orderFrontRegardless()
    }

    /// Called by the SwiftUI root whenever its natural size changes; the panel grows upward from its bottom-left corner.
    func updatePanelSize(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let origin = panel.frame.origin
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}
