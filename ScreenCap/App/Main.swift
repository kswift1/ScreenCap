import AppKit

/// Explicit entry point: without a MainMenu.xib, AppKit will not instantiate the delegate for us.
@main
@MainActor
enum ScreenCapMain {
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.run()
    }
}
