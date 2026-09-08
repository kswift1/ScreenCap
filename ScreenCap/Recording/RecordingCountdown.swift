import AppKit
import SwiftUI

/// Full-screen, click-through, non-activating panel that shows a large countdown number centered
/// on the region about to be recorded. Becomes key (without activating the app) so Esc can cancel.
final class RecordingCountdownPanel: NSPanel {
    private let model = CountdownModel()
    private let onCancel: () -> Void

    init(screen: NSScreen, region: CGRect, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let local = CGRect(x: region.minX - screen.frame.minX, y: region.minY - screen.frame.minY,
                           width: region.width, height: region.height)
        contentView = NSHostingView(rootView: CountdownView(model: model, region: local, screenSize: screen.frame.size))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Updates the displayed number (seconds remaining).
    func show(_ seconds: Int) {
        model.seconds = seconds
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

@MainActor
final class CountdownModel: ObservableObject {
    @Published var seconds = 0
}

/// Dashed outline of the region plus the big number and an Esc hint.
struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    let region: CGRect
    let screenSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: region.width, height: region.height)
                .offset(x: region.minX, y: screenSize.height - region.maxY)

            VStack(spacing: 10) {
                Text("\(model.seconds)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.25), value: model.seconds)
                Text("Recording starts soon · Esc to cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 28)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color.black.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.15)))
            .position(x: region.midX, y: screenSize.height - region.midY)
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }
}
