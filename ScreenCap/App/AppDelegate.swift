import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Preferences.registerDefaults()
        MainMenu.install()
        statusBar = StatusBarController()
        HotkeyManager.shared.registerAll()
        FileStore.cleanupTemporaryFiles()

        if !Preferences.hasLaunchedBefore {
            Preferences.hasLaunchedBefore = true
            Permissions.ensureScreenCaptureAccess(showAlert: false)
            SettingsWindowController.shared.show()
        }
        handleDebugArguments()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregisterAll()
    }

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}

// MARK: - Development helpers

private var debugSelectionSession: SelectionSession?

extension AppDelegate {
    /// `ScreenCap --open-editor <image>` opens the annotation editor on any image;
    /// `ScreenCap --debug-overlay` shows the selection overlay and prints the result without capturing.
    fileprivate func handleDebugArguments() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open-editor"), i + 1 < args.count,
           let image = CGImage.load(from: URL(fileURLWithPath: args[i + 1])) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            EditorWindowController.open(image: image, pixelScale: scale, sourceItem: nil)
        }
        if args.contains("--debug-overlay") {
            let session = SelectionSession(mode: .area) { result in
                debugSelectionSession = nil
                switch result {
                case .area(let screen, let rect): NSLog("overlay: area %@ on display %u", NSStringFromRect(rect), screen.displayID)
                case .window(let w): NSLog("overlay: window %@ %@", w.displayName, NSStringFromRect(w.frame))
                case .cancelled: NSLog("overlay: cancelled")
                }
            }
            debugSelectionSession = session
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { session.begin() }
        }
    }
}
