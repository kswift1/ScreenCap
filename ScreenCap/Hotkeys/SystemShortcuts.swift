import AppKit

/// Detects whether macOS's own screenshot shortcuts (⇧⌘3 / ⇧⌘4 / ⇧⌘5) are still enabled.
/// The system handles those before any app hotkey, so ours would silently never fire.
enum SystemShortcuts {
    /// AppleSymbolicHotKeys IDs: 28 = ⇧⌘3 (save fullscreen), 30 = ⇧⌘4 (save selection), 184 = ⇧⌘5 (screenshot toolbar).
    private static let screenshotIDs: [String: String] = ["28": "⇧⌘3", "30": "⇧⌘4", "184": "⇧⌘5"]

    /// System screenshot shortcuts that are enabled *and* collide with one of our bindings.
    @MainActor
    static func conflictingShortcuts() -> [String] {
        let enabled = enabledScreenshotShortcuts()
        guard !enabled.isEmpty else { return [] }
        let ours = Set(HotkeyManager.shared.bindings.values.filter { !$0.isNone }.map(\.displayString))
        return enabled.filter { ours.contains($0) }.sorted()
    }

    private static func enabledScreenshotShortcuts() -> [String] {
        let dict = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        return screenshotIDs.compactMap { id, name in
            // A missing entry means the shortcut is at its default (enabled).
            guard let entry = dict[id] as? [String: Any] else { return name }
            let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? true
            return enabled ? name : nil
        }
    }

    static func openKeyboardShortcutSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") {
            NSWorkspace.shared.open(url)
        }
    }
}
