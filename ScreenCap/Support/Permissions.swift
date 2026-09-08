import AppKit

enum Permissions {
    /// Returns true when Screen Recording access is granted. Otherwise triggers the system prompt
    /// (first time only) and optionally explains how to enable it.
    @discardableResult
    static func ensureScreenCaptureAccess(showAlert: Bool = true) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }
        if showAlert { presentAlert() }
        return false
    }

    private static func presentAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission required"
        alert.informativeText = "ScreenCap needs Screen Recording access to capture your screen.\n\nEnable it in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch ScreenCap."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum ErrorPresenter {
    @MainActor
    static func show(_ error: Error, title: String = "Something went wrong") {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
