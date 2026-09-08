import AppKit
import SwiftUI

/// Small transient toast shown after text recognition ("Copied 5 lines", "No text found", ...).
/// A non-activating borderless panel placed just below (or above) the captured region; auto-dismisses,
/// or dismisses on click.
@MainActor
final class OCRResultHUD {
    static let shared = OCRResultHUD()

    /// What the toast displays.
    struct Content {
        var symbol: String
        var title: String
        var detail: String?
        var openURL: URL?
    }

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private let dismissDelay: Duration = .seconds(2.5)
    private let margin: CGFloat = 8

    /// Shows `content` next to `sourceRect` (Cocoa screen coordinates), replacing any toast already on screen.
    func show(_ content: Content, near sourceRect: CGRect) {
        dismissTask?.cancel()
        let panel = makePanelIfNeeded()
        let hosting = NSHostingView(rootView: OCRResultHUDView(content: content, onDismiss: { [weak self] in
            self?.dismiss()
        }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        let size = hosting.fittingSize
        panel.setFrame(CGRect(origin: origin(for: size, near: sourceRect), size: size), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: self?.dismissDelay ?? .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Fades the toast out and hides the panel.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    // MARK: Layout

    /// Centres the toast under the region; flips above it when there's no room below. Clamped to the screen.
    private func origin(for size: CGSize, near rect: CGRect) -> CGPoint {
        let screen = NSScreen.containing(rect).visibleFrame
        var x = rect.midX - size.width / 2
        x = min(max(x, screen.minX + margin), screen.maxX - size.width - margin)
        var y = rect.minY - margin - size.height
        if y < screen.minY + margin {
            y = rect.maxY + margin
        }
        y = min(max(y, screen.minY + margin), screen.maxY - size.height - margin)
        return CGPoint(x: x, y: y)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 240, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2) // visible on full-screen Spaces too
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel = p
        return p
    }
}

/// SwiftUI body of the OCR toast: icon, title, optional detail line, optional "Open" button.
struct OCRResultHUDView: View {
    let content: OCRResultHUD.Content
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: content.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                if let detail = content.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if let url = content.openURL {
                Button("Open") {
                    NSWorkspace.shared.open(url)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 180, maxWidth: 360, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
    }
}
