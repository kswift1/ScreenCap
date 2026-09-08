import AppKit
import Carbon.HIToolbox

/// Registers global shortcuts through Carbon's RegisterEventHotKey, which needs no
/// Accessibility permission and swallows the key event so the front app never sees it.
@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published private(set) var bindings: [HotkeyAction: Hotkey] = [:]

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actionsByID: [UInt32: HotkeyAction] = [:]
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x5343_4150 // 'SCAP'
    /// While a recorder field is capturing a new shortcut we suspend all global hotkeys.
    private var suspended = false

    private init() {
        let stored = Preferences.hotkeyBindings
        for action in HotkeyAction.allCases {
            bindings[action] = stored[action.rawValue] ?? action.defaultHotkey
        }
    }

    func binding(for action: HotkeyAction) -> Hotkey? {
        guard let hk = bindings[action], !hk.isNone else { return nil }
        return hk
    }

    func set(_ hotkey: Hotkey, for action: HotkeyAction) {
        // Steal the shortcut from any other action that already uses it.
        if !hotkey.isNone {
            for (other, hk) in bindings where other != action && hk == hotkey {
                bindings[other] = .none
            }
        }
        bindings[action] = hotkey
        persist()
        registerAll()
    }

    func resetToDefaults() {
        for action in HotkeyAction.allCases { bindings[action] = action.defaultHotkey }
        persist()
        registerAll()
    }

    private func persist() {
        var out: [String: Hotkey] = [:]
        for (a, hk) in bindings { out[a.rawValue] = hk }
        Preferences.hotkeyBindings = out
        NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
    }

    func suspend() { suspended = true; unregisterAll() }
    func resume() { suspended = false; registerAll() }

    func registerAll() {
        guard !suspended else { return }
        installHandlerIfNeeded()
        unregisterAll()
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let hk = binding(for: action) else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: signature, id: id)
            let status = RegisterEventHotKey(hk.keyCode, hk.carbonModifiers, hkID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[id] = ref
                actionsByID[id] = action
            } else {
                NSLog("ScreenCap: failed to register hotkey \(hk.displayString) for \(action.rawValue): \(status)")
            }
        }
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actionsByID.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr else { return OSStatus(eventNotHandledErr) }
            let id = hkID.id
            Task { @MainActor in HotkeyManager.shared.handle(id: id) }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    private func handle(id: UInt32) {
        guard let action = actionsByID[id] else { return }
        CaptureCoordinator.shared.perform(action)
    }
}
