import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut expressed in Carbon terms (virtual key code + Carbon modifier mask).
struct Hotkey: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Sentinel meaning "no shortcut assigned".
    static let none = Hotkey(keyCode: UInt32.max, carbonModifiers: 0)
    var isNone: Bool { keyCode == UInt32.max }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        self.carbonModifiers = Hotkey.carbonFlags(from: modifierFlags)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        return f
    }

    static func carbonFlags(from f: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if f.contains(.control) { c |= UInt32(controlKey) }
        if f.contains(.option) { c |= UInt32(optionKey) }
        if f.contains(.shift) { c |= UInt32(shiftKey) }
        if f.contains(.command) { c |= UInt32(cmdKey) }
        return c
    }

    /// e.g. "⌃⇧2"
    var displayString: String {
        if isNone { return "None" }
        var s = ""
        let f = modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + KeyCodeNames.name(for: UInt16(keyCode))
    }

    /// Mirrors the shortcut on a menu item so it shows up next to the title.
    func apply(to item: NSMenuItem) {
        guard !isNone, let ch = KeyCodeNames.keyEquivalent(for: UInt16(keyCode)) else { return }
        item.keyEquivalent = ch
        item.keyEquivalentModifierMask = modifierFlags
    }
}

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case captureFullscreen
    case captureArea
    case captureWindow
    case pinArea
    case toggleRecording
    case openLastCapture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .pinArea: return "Pin Area"
        case .toggleRecording: return "Record Screen"
        case .openLastCapture: return "Open Last Capture"
        }
    }

    var symbol: String {
        switch self {
        case .captureFullscreen: return "macwindow"
        case .captureArea: return "rectangle.dashed"
        case .captureWindow: return "macwindow.on.rectangle"
        case .pinArea: return "pin"
        case .toggleRecording: return "record.circle"
        case .openLastCapture: return "clock.arrow.circlepath"
        }
    }

    var defaultHotkey: Hotkey {
        let shiftCmd = UInt32(shiftKey | cmdKey)
        switch self {
        case .captureFullscreen: return Hotkey(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: shiftCmd)
        case .captureArea: return Hotkey(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: shiftCmd)
        case .captureWindow: return Hotkey(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: shiftCmd)
        case .pinArea: return Hotkey(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: shiftCmd)
        case .toggleRecording: return Hotkey(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: shiftCmd)
        case .openLastCapture: return Hotkey(keyCode: UInt32(kVK_ANSI_6), carbonModifiers: shiftCmd)
        }
    }
}

/// Human-readable names and menu key equivalents for virtual key codes.
enum KeyCodeNames {
    private static let special: [UInt16: String] = [
        UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘", UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]

    private static let menuEquivalents: [UInt16: String] = [
        UInt16(kVK_Return): "\r", UInt16(kVK_Tab): "\t", UInt16(kVK_Space): " ",
        UInt16(kVK_Delete): "\u{8}", UInt16(kVK_ForwardDelete): "\u{7F}", UInt16(kVK_Escape): "\u{1B}",
        UInt16(kVK_LeftArrow): "\u{F702}", UInt16(kVK_RightArrow): "\u{F703}",
        UInt16(kVK_UpArrow): "\u{F700}", UInt16(kVK_DownArrow): "\u{F701}",
        UInt16(kVK_F1): "\u{F704}", UInt16(kVK_F2): "\u{F705}", UInt16(kVK_F3): "\u{F706}", UInt16(kVK_F4): "\u{F707}",
        UInt16(kVK_F5): "\u{F708}", UInt16(kVK_F6): "\u{F709}", UInt16(kVK_F7): "\u{F70A}", UInt16(kVK_F8): "\u{F70B}",
        UInt16(kVK_F9): "\u{F70C}", UInt16(kVK_F10): "\u{F70D}", UInt16(kVK_F11): "\u{F70E}", UInt16(kVK_F12): "\u{F70F}",
    ]

    static func name(for keyCode: UInt16) -> String {
        if let s = special[keyCode] { return s }
        return translate(keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    static func keyEquivalent(for keyCode: UInt16) -> String? {
        if let s = menuEquivalents[keyCode] { return s }
        return translate(keyCode)?.lowercased()
    }

    /// Uses the current keyboard layout to turn a virtual key code into its unmodified character.
    private static func translate(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
