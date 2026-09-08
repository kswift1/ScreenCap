import AppKit
import ScreenCaptureKit

/// Thin wrapper over ScreenCaptureKit's one-shot screenshot API.
enum CaptureEngine {
    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Content filter for a display that hides every ScreenCap window (overlays, Quick Access…).
    static func displayFilter(for screen: NSScreen, content: SCShareableContent) throws -> SCContentFilter {
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.displayNotFound
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
    }

    /// Captures `rect` (Cocoa screen coordinates, in points) of `screen`; nil captures the whole display.
    static func captureDisplay(_ screen: NSScreen, rect: CGRect? = nil) async throws -> CGImage {
        let content = try await shareableContent()
        let filter = try displayFilter(for: screen, content: content)
        let scale = screen.backingScaleFactor
        let region = (rect ?? screen.frame).intersection(screen.frame).integral
        let relative = region.relativeToTopLeft(of: screen)

        let config = SCStreamConfiguration()
        config.sourceRect = relative
        config.width = Int(relative.width * scale)
        config.height = Int(relative.height * scale)
        config.showsCursor = Preferences.showCursor
        config.captureResolution = .best
        config.ignoreShadowsDisplay = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Captures a single window (no desktop behind it, no shadow) at the given scale.
    static func captureWindow(id: CGWindowID, scale: CGFloat) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
