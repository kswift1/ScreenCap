import SwiftUI
import AVFoundation
import ServiceManagement
import Carbon.HIToolbox

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gear") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            RecordingSettings()
                .tabItem { Label("Recording", systemImage: "record.circle") }
        }
        .frame(width: 520, height: 460)
    }
}

struct GeneralSettings: View {
    @AppStorage(Preferences.Key.saveDirectory) private var saveDirectory = Preferences.Default.saveDirectory.path
    @AppStorage(Preferences.Key.fileFormat) private var fileFormat = Preferences.Default.fileFormat.rawValue
    @AppStorage(Preferences.Key.copyToClipboard) private var copyToClipboard = Preferences.Default.copyToClipboard
    @AppStorage(Preferences.Key.autoSave) private var autoSave = Preferences.Default.autoSave
    @AppStorage(Preferences.Key.showQuickAccess) private var showQuickAccess = Preferences.Default.showQuickAccess
    @AppStorage(Preferences.Key.quickAccessDuration) private var quickAccessDuration = Preferences.Default.quickAccessDuration
    @AppStorage(Preferences.Key.showCursor) private var showCursor = Preferences.Default.showCursor
    @AppStorage(Preferences.Key.playSound) private var playSound = Preferences.Default.playSound
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasPermission = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section("After capture") {
                Toggle("Show Quick Access overlay", isOn: $showQuickAccess)
                if showQuickAccess {
                    Picker("Auto-dismiss after", selection: $quickAccessDuration) {
                        Text("3 seconds").tag(3.0)
                        Text("5 seconds").tag(5.0)
                        Text("8 seconds").tag(8.0)
                        Text("15 seconds").tag(15.0)
                        Text("Never").tag(0.0)
                    }
                }
                Toggle("Copy to clipboard", isOn: $copyToClipboard)
                Toggle("Save to folder automatically", isOn: $autoSave)
            }

            Section("Files") {
                LabeledContent("Save to") {
                    HStack {
                        Text(abbreviated(saveDirectory)).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Picker("Image format", selection: $fileFormat) {
                    ForEach(ImageFormat.allCases) { f in Text(f.title).tag(f.rawValue) }
                }
            }

            Section("Screenshots") {
                Toggle("Include mouse cursor", isOn: $showCursor)
                Toggle("Play capture sound", isOn: $playSound)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                LabeledContent("Screen Recording permission") {
                    HStack {
                        Image(systemName: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(hasPermission ? .green : .orange)
                        Text(hasPermission ? "Granted" : "Not granted")
                        if !hasPermission {
                            Button("Open System Settings") { Permissions.openSystemSettings() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = CGPreflightScreenCaptureAccess()
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url.path
        }
    }
}

struct ShortcutSettings: View {
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var conflicts = SystemShortcuts.conflictingShortcuts()

    var body: some View {
        Form {
            if !conflicts.isEmpty {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("macOS is still using \(conflicts.joined(separator: ", ")) for its own screenshots, so ScreenCap won't receive them.")
                            Text("Turn off the Screenshots shortcuts in System Settings → Keyboard → Keyboard Shortcuts, then come back.")
                                .foregroundStyle(.secondary)
                            Button("Open Keyboard Shortcuts…") { SystemShortcuts.openKeyboardShortcutSettings() }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent {
                        HotkeyRecorder(hotkey: hotkeys.bindings[action] ?? .none) { hotkeys.set($0, for: action) }
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            } footer: {
                Text("Click a shortcut and press the new key combination. Press ⌫ to remove it, or Esc to keep the current one.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") { hotkeys.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            conflicts = SystemShortcuts.conflictingShortcuts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotkeysDidChange)) { _ in
            conflicts = SystemShortcuts.conflictingShortcuts()
        }
    }
}

struct RecordingSettings: View {
    @AppStorage(Preferences.Key.recordFPS) private var recordFPS = Preferences.Default.recordFPS
    @AppStorage(Preferences.Key.recordCursor) private var recordCursor = Preferences.Default.recordCursor
    @AppStorage(Preferences.Key.recordAudio) private var recordAudio = Preferences.Default.recordAudio
    @AppStorage(Preferences.Key.recordCountdown) private var recordCountdown = Preferences.Default.recordCountdown
    @AppStorage(Preferences.Key.recordMicrophone) private var recordMicrophone = Preferences.Default.recordMicrophone
    @AppStorage(Preferences.Key.recordClickHighlight) private var recordClickHighlight = Preferences.Default.recordClickHighlight
    @AppStorage(Preferences.Key.gifFPS) private var gifFPS = Preferences.Default.gifFPS
    @AppStorage(Preferences.Key.gifMaxWidth) private var gifMaxWidth = Preferences.Default.gifMaxWidth
    @State private var microphoneDenied = Self.isMicrophoneDenied()

    var body: some View {
        Form {
            Section("Video") {
                Picker("Frame rate", selection: $recordFPS) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Show mouse cursor", isOn: $recordCursor)
                Toggle("Highlight mouse clicks", isOn: $recordClickHighlight)
                Picker("Countdown", selection: $recordCountdown) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            }
            Section {
                Toggle("Record system audio", isOn: $recordAudio)
                Toggle("Record microphone", isOn: $recordMicrophone)
                if recordMicrophone, microphoneDenied {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Microphone access is off. Recordings will have no microphone until it's allowed.")
                            .foregroundStyle(.secondary)
                        Button("Open Privacy Settings") { openMicrophoneSettings() }
                    }
                    .font(.callout)
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("System audio and the microphone are mixed into the video file. Pause/resume splits the recording into segments that are joined when you stop.")
                    .foregroundStyle(.secondary)
            }
            Section("GIF conversion") {
                Picker("Frame rate", selection: $gifFPS) {
                    Text("8 fps").tag(8)
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("20 fps").tag(20)
                }
                Picker("Maximum width", selection: $gifMaxWidth) {
                    Text("480 px").tag(480)
                    Text("640 px").tag(640)
                    Text("800 px").tag(800)
                    Text("1080 px").tag(1080)
                    Text("Original").tag(100_000)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphoneDenied = Self.isMicrophoneDenied()
        }
    }

    /// True once the user has explicitly refused (or policy blocks) microphone access.
    private static func isMicrophoneDenied() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Click, then press a combination. Global hotkeys are suspended while recording so they don't fire.
struct HotkeyRecorder: View {
    let hotkey: Hotkey
    let onChange: (Hotkey) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : hotkey.displayString)
                .font(.system(size: 12, weight: .medium, design: hotkey.isNone && !recording ? .default : .rounded))
                .foregroundStyle(recording ? Color.accentColor : (hotkey.isNone ? .secondary : .primary))
                .frame(minWidth: 96)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(recording ? Color.accentColor : Color.secondary.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotkeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            switch event.keyCode {
            case 53: // Esc keeps the current shortcut
                stop()
            case 51, 117: // Delete clears it
                onChange(.none)
                stop()
            default:
                let isFunctionKey = (UInt16(kVK_F1)...UInt16(kVK_F20)).contains(event.keyCode)
                guard !flags.isEmpty || isFunctionKey else { return nil }
                onChange(Hotkey(keyCode: event.keyCode, modifierFlags: flags))
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotkeyManager.shared.resume()
    }
}
