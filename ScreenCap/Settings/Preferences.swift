import AppKit

/// UserDefaults-backed preferences. SwiftUI views bind with `@AppStorage(Preferences.Key.x)`
/// using the same keys; non-view code reads the static accessors.
enum Preferences {
    enum Key {
        static let saveDirectory = "saveDirectory"
        static let fileFormat = "fileFormat"
        static let copyToClipboard = "copyToClipboard"
        static let autoSave = "autoSave"
        static let showQuickAccess = "showQuickAccess"
        static let quickAccessDuration = "quickAccessDuration"
        static let showCursor = "showCursor"
        static let playSound = "playSound"
        static let recordCursor = "recordCursor"
        static let recordAudio = "recordAudio"
        static let recordFPS = "recordFPS"
        static let recordCountdown = "recordCountdown"
        static let recordMicrophone = "recordMicrophone"
        static let recordClickHighlight = "recordClickHighlight"
        static let gifFPS = "gifFPS"
        static let gifMaxWidth = "gifMaxWidth"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let hotkeys = "hotkeys"
    }

    enum Default {
        static var saveDirectory: URL {
            FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        static let fileFormat = ImageFormat.png
        static let copyToClipboard = true
        static let autoSave = false
        static let showQuickAccess = true
        static let quickAccessDuration = 8.0
        static let showCursor = false
        static let playSound = true
        static let recordCursor = true
        static let recordAudio = false
        static let recordFPS = 30
        static let recordCountdown = 0
        static let recordMicrophone = false
        static let recordClickHighlight = false
        static let gifFPS = 10
        static let gifMaxWidth = 800
    }

    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            Key.saveDirectory: Default.saveDirectory.path,
            Key.fileFormat: Default.fileFormat.rawValue,
            Key.copyToClipboard: Default.copyToClipboard,
            Key.autoSave: Default.autoSave,
            Key.showQuickAccess: Default.showQuickAccess,
            Key.quickAccessDuration: Default.quickAccessDuration,
            Key.showCursor: Default.showCursor,
            Key.playSound: Default.playSound,
            Key.recordCursor: Default.recordCursor,
            Key.recordAudio: Default.recordAudio,
            Key.recordFPS: Default.recordFPS,
            Key.recordCountdown: Default.recordCountdown,
            Key.recordMicrophone: Default.recordMicrophone,
            Key.recordClickHighlight: Default.recordClickHighlight,
            Key.gifFPS: Default.gifFPS,
            Key.gifMaxWidth: Default.gifMaxWidth,
        ])
    }

    static var saveDirectory: URL {
        get { URL(fileURLWithPath: d.string(forKey: Key.saveDirectory) ?? Default.saveDirectory.path, isDirectory: true) }
        set { d.set(newValue.path, forKey: Key.saveDirectory) }
    }
    static var fileFormat: ImageFormat {
        ImageFormat(rawValue: d.string(forKey: Key.fileFormat) ?? "") ?? Default.fileFormat
    }
    static var copyToClipboard: Bool { d.bool(forKey: Key.copyToClipboard) }
    static var autoSave: Bool { d.bool(forKey: Key.autoSave) }
    static var showQuickAccess: Bool { d.bool(forKey: Key.showQuickAccess) }
    static var quickAccessDuration: Double { d.double(forKey: Key.quickAccessDuration) }
    static var showCursor: Bool { d.bool(forKey: Key.showCursor) }
    static var playSound: Bool { d.bool(forKey: Key.playSound) }
    static var recordCursor: Bool { d.bool(forKey: Key.recordCursor) }
    static var recordAudio: Bool { d.bool(forKey: Key.recordAudio) }
    static var recordFPS: Int { max(1, d.integer(forKey: Key.recordFPS)) }
    /// Seconds shown before a recording starts; 0 disables the countdown.
    static var recordCountdown: Int { max(0, d.integer(forKey: Key.recordCountdown)) }
    static var recordMicrophone: Bool { d.bool(forKey: Key.recordMicrophone) }
    static var recordClickHighlight: Bool { d.bool(forKey: Key.recordClickHighlight) }
    static var gifFPS: Int { max(1, d.integer(forKey: Key.gifFPS)) }
    static var gifMaxWidth: Int { max(100, d.integer(forKey: Key.gifMaxWidth)) }

    static var hasLaunchedBefore: Bool {
        get { d.bool(forKey: Key.hasLaunchedBefore) }
        set { d.set(newValue, forKey: Key.hasLaunchedBefore) }
    }

    static var hotkeyBindings: [String: Hotkey] {
        get {
            guard let data = d.data(forKey: Key.hotkeys),
                  let decoded = try? JSONDecoder().decode([String: Hotkey].self, from: data) else { return [:] }
            return decoded
        }
        set {
            d.set(try? JSONEncoder().encode(newValue), forKey: Key.hotkeys)
        }
    }
}
