import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// Scrolling capture: scrolls the content under `rect` with synthetic scroll-wheel events and stitches the
/// frames into one tall image. Progress shows in a small floating panel; Esc or its Stop button ends the
/// capture early with what was collected so far. The app never activates.
@MainActor
final class ScrollCaptureController: ObservableObject {
    static let shared = ScrollCaptureController()

    enum Phase: Equatable {
        case idle
        case scrolling
        case finishing
    }

    @Published private(set) var phase: Phase = .idle
    /// Height of the stitched image so far, in pixels.
    @Published private(set) var stitchedHeight = 0

    var isRunning: Bool { phase != .idle }

    /// Fraction of the region height scrolled per step.
    private let stepFraction: CGFloat = 0.65
    /// Pixels per posted scroll event; a step is split into several so apps apply it like a real wheel.
    private let eventChunk = 120
    private let settleDelay: Duration = .milliseconds(120)
    private let settlePoll: Duration = .milliseconds(60)
    private let maxSettlePolls = 8
    /// Consecutive unchanged frames that mean the end of the content.
    private let stillLimit = 2

    private var stopRequested = false
    private var chrome: ScrollCaptureChrome?
    private var escapeKey: ScrollEscapeHotkey?

    /// `rect` is the scrollable region in Cocoa screen coordinates on `screen`.
    func start(screen: NSScreen, rect: CGRect) async {
        guard phase == .idle else { return }
        let region = rect.intersection(screen.frame).integral
        guard region.width >= 8, region.height >= 8 else { return }

        phase = .scrolling
        stitchedHeight = 0
        stopRequested = false
        let chrome = ScrollCaptureChrome(controller: self, region: region, screen: screen)
        chrome.show()
        self.chrome = chrome
        escapeKey = ScrollEscapeHotkey()

        let session = ScrollStitchSession()
        var outcome = Outcome.stopped
        do {
            outcome = try await run(session: session, screen: screen, region: region)
        } catch is CancellationError {
            outcome = .stopped
        } catch {
            outcome = await session.hasMoved ? .stopped : .failed(error)
        }
        await finish(session: session, outcome: outcome, screen: screen, region: region)
    }

    /// Ends the capture after the current step; the collected frames are still delivered.
    func stop() {
        guard phase == .scrolling else { return }
        stopRequested = true
        phase = .finishing
    }

    // MARK: Capture loop

    private enum Outcome {
        /// Content stopped changing, or the height limit was reached, or the user stopped.
        case stopped
        /// The very first scroll changed nothing.
        case notScrollable
        /// A frame could not be aligned with the previous one.
        case lostTrack
        case failed(Error)
    }

    private func run(session: ScrollStitchSession, screen: NSScreen, region: CGRect) async throws -> Outcome {
        let content = try await CaptureEngine.shareableContent()
        let filter = try CaptureEngine.displayFilter(for: screen, content: content)
        let scale = screen.backingScaleFactor
        let relative = region.relativeToTopLeft(of: screen)
        let config = SCStreamConfiguration()
        config.sourceRect = relative
        config.width = Int(relative.width * scale)
        config.height = Int(relative.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let capture: () async throws -> CGImage = {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }

        guard let first = session.makeFrame(try await capture()) else { throw CaptureError.displayNotFound }
        await session.begin(with: first)
        stitchedHeight = await session.totalHeight

        let stepPoints = max(1, Int(region.height * stepFraction))
        let expectedPixels = Int(CGFloat(stepPoints) * scale)
        let target = CGPoint(x: region.midX, y: NSScreen.primaryHeight - region.midY)
        // Scroll events go to the window under the cursor, so park it in the region first.
        CGWarpMouseCursorPosition(target)

        var direction = -1 // negative wheel delta scrolls towards the end of the content
        var stillCount = 0
        while !stopRequested, !Task.isCancelled {
            postScroll(pixels: stepPoints * direction, at: target)
            let frame = try await captureSettledFrame(capture, session: session)
            if stopRequested || Task.isCancelled { break }

            switch await session.append(frame, expected: expectedPixels) {
            case .forward:
                stillCount = 0
                stitchedHeight = await session.totalHeight
                if stitchedHeight >= ScrollStitchSession.maxHeight { return .stopped }
            case .backward:
                // The first step moved the wrong way (inverted scrolling): flip and restart from here.
                direction = -direction
                await session.begin(with: frame)
            case .still:
                stillCount += 1
                if stillCount >= stillLimit {
                    return await session.hasMoved ? .stopped : .notScrollable
                }
            case .lost:
                return .lostTrack
            }
        }
        return .stopped
    }

    /// Waits `settleDelay`, then polls until two consecutive frames match (or gives up after a few polls).
    private func captureSettledFrame(_ capture: () async throws -> CGImage, session: ScrollStitchSession) async throws -> ScrollFrame {
        try await Task.sleep(for: settleDelay)
        guard var previous = session.makeFrame(try await capture()) else { throw CaptureError.displayNotFound }
        for _ in 0..<maxSettlePolls where !stopRequested {
            try await Task.sleep(for: settlePoll)
            guard let next = session.makeFrame(try await capture()) else { throw CaptureError.displayNotFound }
            if ScrollStitcher.areIdentical(previous, next) { return next }
            previous = next
        }
        return previous
    }

    /// Posts pixel-precise scroll-wheel events at `point` (CG coordinates) totalling `pixels` (negative = down).
    private func postScroll(pixels: Int, at point: CGPoint) {
        var remaining = abs(pixels)
        let sign: Int32 = pixels < 0 ? -1 : 1
        while remaining > 0 {
            let chunk = min(remaining, eventChunk)
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: sign * Int32(chunk), wheel2: 0, wheel3: 0) else { return }
            event.location = point
            event.post(tap: .cghidEventTap)
            remaining -= chunk
        }
    }

    // MARK: Finish

    private func finish(session: ScrollStitchSession, outcome: Outcome, screen: NSScreen, region: CGRect) async {
        phase = .finishing
        let image = await session.compose()
        chrome?.hide()
        chrome = nil
        escapeKey?.invalidate()
        escapeKey = nil
        phase = .idle

        switch outcome {
        case .failed(let error):
            ErrorPresenter.show(error, title: "Scrolling capture failed")
            return
        case .notScrollable:
            if AXIsProcessTrusted() {
                OCRResultHUD.shared.show(.init(symbol: "arrow.up.and.down.text.horizontal", title: "Nothing to scroll",
                                               detail: "Captured a single frame"), near: region)
            } else {
                // Synthetic scroll events are dropped until the app is trusted for Accessibility.
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
                OCRResultHUD.shared.show(.init(symbol: "hand.raised", title: "Accessibility access needed to scroll",
                                               detail: "System Settings → Privacy & Security → Accessibility"), near: region)
            }
        case .lostTrack:
            OCRResultHUD.shared.show(.init(symbol: "exclamationmark.triangle", title: "Lost track while scrolling",
                                           detail: "Saved what was captured so far"), near: region)
        case .stopped:
            break
        }
        if let image {
            CaptureCoordinator.shared.finish(image: image, pixelScale: screen.backingScaleFactor, sourceRect: region)
        }
    }
}

/// Temporary global Esc shortcut (Carbon) that stops the scroll capture without activating the app.
/// Installed after HotkeyManager's handler, so it sees the event first and passes everything else along.
@MainActor
final class ScrollEscapeHotkey {
    private static let signature: OSType = 0x5343_524C // 'SCRL'
    private static let hotkeyID: UInt32 = 1
    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr, hkID.signature == ScrollEscapeHotkey.signature, hkID.id == ScrollEscapeHotkey.hotkeyID else {
                return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in ScrollCaptureController.shared.stop() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotkeyID)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &hotkeyRef)
        if status != noErr { NSLog("ScreenCap: couldn't register Esc for scrolling capture: \(status)") }
    }

    func invalidate() {
        if let hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        hotkeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}
