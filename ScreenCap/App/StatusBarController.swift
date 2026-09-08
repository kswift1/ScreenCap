import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        updateIcon(recording: false)

        ScreenRecorder.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.updateIcon(recording: state.isActive) }
            .store(in: &cancellables)
    }

    private func updateIcon(recording: Bool) {
        guard let button = item.button else { return }
        if recording {
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = image?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
        } else {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ScreenCap")
            button.image?.isTemplate = true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if ScreenRecorder.shared.state.isActive {
            let stop = NSMenuItem(title: "Stop Recording", action: #selector(runAction(_:)), keyEquivalent: "")
            stop.target = self
            stop.representedObject = HotkeyAction.toggleRecording.rawValue
            stop.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
            HotkeyManager.shared.binding(for: .toggleRecording)?.apply(to: stop)
            menu.addItem(stop)
        } else {
            for action in HotkeyAction.allCases where action != .openLastCapture {
                let mi = NSMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = action.rawValue
                mi.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                HotkeyManager.shared.binding(for: action)?.apply(to: mi)
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())

        let last = NSMenuItem(title: HotkeyAction.openLastCapture.title, action: #selector(runAction(_:)), keyEquivalent: "")
        last.target = self
        last.representedObject = HotkeyAction.openLastCapture.rawValue
        last.image = NSImage(systemSymbolName: HotkeyAction.openLastCapture.symbol, accessibilityDescription: nil)
        last.isEnabled = !CaptureCoordinator.shared.history.isEmpty
        HotkeyManager.shared.binding(for: .openLastCapture)?.apply(to: last)
        menu.addItem(last)

        if !PinController.shared.pins.isEmpty {
            let close = NSMenuItem(title: "Close All Pins (\(PinController.shared.pins.count))", action: #selector(closePins(_:)), keyEquivalent: "")
            close.target = self
            close.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil)
            menu.addItem(close)
        }

        let folder = NSMenuItem(title: "Open Captures Folder", action: #selector(openFolder(_:)), keyEquivalent: "")
        folder.target = self
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(folder)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit ScreenCap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotkeyAction(rawValue: raw) else { return }
        // Let the menu close before we throw up overlays.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CaptureCoordinator.shared.perform(action)
        }
    }

    @objc private func closePins(_ sender: Any?) {
        PinController.shared.closeAll()
    }

    @objc private func openFolder(_ sender: Any?) {
        NSWorkspace.shared.open(Preferences.saveDirectory)
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}
