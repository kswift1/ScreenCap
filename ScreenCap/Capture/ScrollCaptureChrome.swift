import AppKit
import SwiftUI

/// On-screen chrome for a scrolling capture: a thin frame around the region and a small status panel
/// with the stitched height and a Stop button. Both are non-activating panels and, like every ScreenCap
/// window, excluded from the captured frames.
@MainActor
final class ScrollCaptureChrome {
    private let framePanel: ScrollFramePanel
    private let statusPanel: ScrollStatusPanel

    init(controller: ScrollCaptureController, region: CGRect, screen: NSScreen) {
        framePanel = ScrollFramePanel(region: region)
        statusPanel = ScrollStatusPanel(controller: controller, region: region, screen: screen)
    }

    func show() {
        framePanel.orderFrontRegardless()
        statusPanel.orderFrontRegardless()
    }

    func hide() {
        framePanel.orderOut(nil)
        statusPanel.orderOut(nil)
    }
}

/// Click-through outline around the region being scrolled.
final class ScrollFramePanel: NSPanel {
    init(region: CGRect) {
        let inset: CGFloat = 3
        super.init(contentRect: region.insetBy(dx: -inset, dy: -inset), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = FrameView(frame: CGRect(origin: .zero, size: frame.size))
    }

    private final class FrameView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            outer.lineWidth = 2
            NSColor.white.withAlphaComponent(0.9).setStroke()
            outer.stroke()
            let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 2, yRadius: 2)
            inner.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            inner.stroke()
        }
    }
}

/// Small floating pill ("Scrolling… 3 200 px", Stop) placed just below (or above) the region.
final class ScrollStatusPanel: NSPanel {
    private static let size = CGSize(width: 250, height: 40)
    private static let margin: CGFloat = 10

    init(controller: ScrollCaptureController, region: CGRect, screen: NSScreen) {
        let size = Self.size
        super.init(contentRect: CGRect(origin: Self.origin(for: size, near: region, on: screen), size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: ScrollStatusView(controller: controller))
    }

    /// Centred under the region; above it when there's no room below; clamped to the screen otherwise.
    private static func origin(for size: CGSize, near rect: CGRect, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        var x = rect.midX - size.width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        var y = rect.minY - margin - size.height
        if y < visible.minY + margin {
            y = rect.maxY + margin
        }
        if y + size.height > visible.maxY - margin {
            // Region fills the screen: sit inside it, at the bottom.
            y = max(visible.minY + margin, rect.minY + margin)
        }
        return CGPoint(x: x, y: y)
    }
}

struct ScrollStatusView: View {
    @ObservedObject var controller: ScrollCaptureController

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(controller.phase == .finishing ? "Finishing…" : "Scrolling…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(Self.heightText(controller.stitchedHeight))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { controller.stop() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Stop")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(.red))
            }
            .buttonStyle(.plain)
            .disabled(controller.phase != .scrolling)
            .help("Stop scrolling and keep what was captured (Esc)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(width: 250, height: 40)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().stroke(.white.opacity(0.15)))
    }

    /// "3 200 px" with a narrow no-break space as the thousands separator.
    static func heightText(_ pixels: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{202F}"
        f.usesGroupingSeparator = true
        return (f.string(from: NSNumber(value: pixels)) ?? "\(pixels)") + " px"
    }
}
