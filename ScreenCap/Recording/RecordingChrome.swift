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

/// Small floating pill with a timer and Pause/Stop/Cancel buttons, docked at the bottom of the display.
final class RecordingControlsPanel: NSPanel {
    static let size = CGSize(width: 268, height: 44)

    init(recorder: ScreenRecorder, screen: NSScreen) {
        let size = Self.size
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
                    indicator(at: context.date)
                    Text(elapsed(at: context.date))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }
            Text("\(Int(recorder.region.width))×\(Int(recorder.region.height))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
            Button { Task { await recorder.togglePause() } } label: {
                Image(systemName: recorder.state.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .disabled(!recorder.state.canPauseOrResume)
            .help(recorder.state.isPaused ? "Resume recording" : "Pause recording")
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
            .disabled(!recorder.state.canPauseOrResume)
            .help("Stop recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(width: RecordingControlsPanel.size.width, height: RecordingControlsPanel.size.height)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().stroke(.white.opacity(0.15)))
    }

    /// Blinking red dot while recording; a steady pause glyph while paused.
    @ViewBuilder
    private func indicator(at date: Date) -> some View {
        if recorder.state.isPaused {
            Image(systemName: "pause.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.yellow)
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(Int(date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.35)
        }
    }

    private func elapsed(at date: Date) -> String {
        let seconds = Int(recorder.elapsed(at: date))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
