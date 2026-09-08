import AppKit

/// Scrolling capture: scrolls the content under `rect` and stitches the frames into one tall image.
/// Stub — implemented by the scroll-capture work stream.
@MainActor
final class ScrollCaptureController {
    static let shared = ScrollCaptureController()

    /// `rect` is the scrollable region in Cocoa screen coordinates on `screen`.
    func start(screen: NSScreen, rect: CGRect) async {
        NSLog("Scrolling capture not implemented yet")
    }
}
