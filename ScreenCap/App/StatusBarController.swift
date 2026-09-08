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
            // Template silhouette of the app icon (Assets.xcassets/MenuBarIcon); falls back to an SF Symbol.
            let icon = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ScreenCap")
            icon?.isTemplate = true
            icon?.accessibilityDescription = "ScreenCap"
            button.image = icon
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
            for action in HotkeyAction.allCases where action != .openLastCapture && action != .togglePins {
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

        let pinController = PinController.shared
        if !pinController.pins.isEmpty || pinController.lastClosed != nil {
            let pinsItem = NSMenuItem(title: "Pins", action: nil, keyEquivalent: "")
            pinsItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
            pinsItem.submenu = buildPinsMenu(pinController)
            menu.addItem(pinsItem)
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

    // MARK: Pins submenu

    /// One row per pin (click: unlock if locked, otherwise bring to front) plus bulk actions.
    private func buildPinsMenu(_ controller: PinController) -> NSMenu {
        let menu = NSMenu(title: "Pins")
        menu.autoenablesItems = false
        let pins = controller.pins

        for panel in pins {
            let mi = NSMenuItem(title: pinTitle(panel), action: #selector(pinRowClicked(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = panel
            mi.image = NSImage(systemSymbolName: panel.isLocked ? "lock.fill" : "pin", accessibilityDescription: nil)
            mi.toolTip = panel.isLocked ? "Locked — click to unlock" : "Click to bring to front"
            menu.addItem(mi)
        }
        if !pins.isEmpty { menu.addItem(.separator()) }

        let unlock = NSMenuItem(title: "Unlock All", action: #selector(unlockPins(_:)), keyEquivalent: "")
        unlock.target = self
        unlock.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: nil)
        unlock.isEnabled = !controller.lockedPins.isEmpty
        menu.addItem(unlock)

        let count = pins.count
        let toggleTitle = controller.isHidden ? "Show Pins (\(count))" : "Hide Pins (\(count))"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(togglePins(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.image = NSImage(systemSymbolName: controller.isHidden ? "eye" : "eye.slash", accessibilityDescription: nil)
        toggle.isEnabled = count > 0
        HotkeyManager.shared.binding(for: .togglePins)?.apply(to: toggle)
        menu.addItem(toggle)

        let close = NSMenuItem(title: "Close All Pins (\(count))", action: #selector(closePins(_:)), keyEquivalent: "")
        close.target = self
        close.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil)
        close.isEnabled = count > 0
        menu.addItem(close)

        menu.addItem(.separator())
        let reopen = NSMenuItem(title: "Reopen Last Closed Pin", action: #selector(reopenPin(_:)), keyEquivalent: "")
        reopen.target = self
        reopen.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        reopen.isEnabled = controller.lastClosed != nil
        menu.addItem(reopen)
        return menu
    }

    /// e.g. "600×400 · 22:41" — current size and the time the capture was taken.
    private func pinTitle(_ panel: PinnedPanel) -> String {
        let size = panel.frame.size
        return "\(Int(size.width.rounded()))×\(Int(size.height.rounded())) · \(Self.timeFormatter.string(from: panel.item.createdAt))"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    @objc private func pinRowClicked(_ sender: NSMenuItem) {
        guard let panel = sender.representedObject as? PinnedPanel else { return }
        if panel.isLocked {
            panel.setLocked(false)
        } else {
            PinController.shared.bringToFront(panel)
        }
    }

    @objc private func unlockPins(_ sender: Any?) {
        PinController.shared.unlockAll()
    }

    @objc private func togglePins(_ sender: Any?) {
        PinController.shared.toggleHidden()
    }

    @objc private func closePins(_ sender: Any?) {
        PinController.shared.closeAll()
    }

    @objc private func reopenPin(_ sender: Any?) {
        PinController.shared.reopenLastClosed()
    }

    @objc private func openFolder(_ sender: Any?) {
        NSWorkspace.shared.open(Preferences.saveDirectory)
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}
