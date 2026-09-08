import AppKit
import SwiftUI

/// Non-interactive outline around the region being recorded. Excluded from the capture
/// because every ScreenCap window is filtered out of the stream.
final class RecordingFramePanel: NSPanel {
    init(region: CGRect) {
        let inset: CGFloat = 4
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
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 3, yRadius: 3)
            path.lineWidth = 3
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.stroke()
            let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 2.5, dy: 2.5), xRadius: 2, yRadius: 2)
            inner.lineWidth = 1
            NSColor.systemRed.setStroke()
            inner.stroke()
        }
    }
}

/// Small floating pill with a timer and Stop/Cancel buttons, docked at the bottom of the display.
final class RecordingControlsPanel: NSPanel {
    init(recorder: ScreenRecorder, screen: NSScreen) {
        let size = CGSize(width: 232, height: 44)
        let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 24)
        super.init(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: RecordingControlsView(recorder: recorder))
    }
}

struct RecordingControlsView: View {
    @ObservedObject var recorder: ScreenRecorder

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .opacity(Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.35)
                    Text(elapsed(at: context.date))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }
            Text("\(Int(recorder.region.width))×\(Int(recorder.region.height))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
            Button { Task { await recorder.stop(discard: true) } } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Cancel and discard")
            Button { Task { await recorder.stop() } } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.red))
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(width: 232, height: 44)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().stroke(.white.opacity(0.15)))
    }

    private func elapsed(at date: Date) -> String {
        let seconds = Int(date.timeIntervalSince(recorder.state.startDate ?? date))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
