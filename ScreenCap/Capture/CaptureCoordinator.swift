import AppKit

/// Orchestrates every capture flow: permission → selection UI → ScreenCaptureKit → post-actions.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private(set) var history: [CaptureItem] = []
    private var selection: SelectionSession?

    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureFullscreen: captureFullscreen()
        case .captureArea: startSelection(mode: .area)
        case .captureWindow: startSelection(mode: .window)
        case .toggleRecording: toggleRecording()
        case .openLastCapture: QuickAccessController.shared.showLast()
        }
    }

    // MARK: Entry points

    func captureFullscreen() {
        guard Permissions.ensureScreenCaptureAccess() else { return }
        cancelSelection()
        let screen = NSScreen.underMouse
        Task {
            do {
                let image = try await CaptureEngine.captureDisplay(screen)
                finish(image: image, pixelScale: screen.backingScaleFactor)
            } catch {
                ErrorPresenter.show(error, title: "Capture failed")
            }
        }
    }

    func toggleRecording() {
        if ScreenRecorder.shared.state.isActive {
            Task { await ScreenRecorder.shared.stop() }
        } else {
            startSelection(mode: .record)
        }
    }

    private func startSelection(mode: SelectionMode) {
        guard Permissions.ensureScreenCaptureAccess() else { return }
        if selection != nil {
            // Pressing the hotkey again while selecting cancels.
            cancelSelection()
            return
        }
        let session = SelectionSession(mode: mode) { [weak self] result in
            guard let self else { return }
            self.selection = nil
            self.handle(result, mode: mode)
        }
        selection = session
        session.begin()
    }

    private func cancelSelection() {
        selection?.cancel()
        selection = nil
    }

    // MARK: Selection results

    private func handle(_ result: SelectionResult, mode: SelectionMode) {
        switch result {
        case .cancelled:
            return

        case .area(let screen, let rect):
            if mode == .record {
                Task { await ScreenRecorder.shared.start(screen: screen, rect: rect) }
            } else {
                Task {
                    do {
                        let image = try await CaptureEngine.captureDisplay(screen, rect: rect)
                        finish(image: image, pixelScale: screen.backingScaleFactor)
                    } catch {
                        ErrorPresenter.show(error, title: "Capture failed")
                    }
                }
            }

        case .window(let info):
            let screen = NSScreen.containing(info.frame)
            if mode == .record {
                let rect = info.frame.intersection(screen.frame)
                Task { await ScreenRecorder.shared.start(screen: screen, rect: rect) }
            } else {
                Task {
                    do {
                        let image: CGImage
                        do {
                            image = try await CaptureEngine.captureWindow(id: info.id, scale: screen.backingScaleFactor)
                        } catch {
                            // Fall back to a display crop if the window vanished from SCK's list.
                            image = try await CaptureEngine.captureDisplay(screen, rect: info.frame)
                        }
                        finish(image: image, pixelScale: screen.backingScaleFactor)
                    } catch {
                        ErrorPresenter.show(error, title: "Capture failed")
                    }
                }
            }
        }
    }

    // MARK: Post-capture

    func finish(image: CGImage, pixelScale: CGFloat) {
        do {
            let item = try CaptureItem(image: image, pixelScale: pixelScale)
            SoundPlayer.playCapture()
            if Preferences.copyToClipboard {
                Clipboard.copy(image: image, pixelScale: pixelScale)
            }
            publish(item)
        } catch {
            ErrorPresenter.show(error, title: "Couldn't save capture")
        }
    }

    func recordingFinished(url: URL, pixelScale: CGFloat) {
        let item = CaptureItem(videoURL: url, pixelScale: pixelScale)
        publish(item)
    }

    func add(gifItem: CaptureItem) {
        publish(gifItem)
    }

    private func publish(_ item: CaptureItem) {
        history.append(item)
        if history.count > 30 { history.removeFirst(history.count - 30) }

        let autoSave = Preferences.autoSave
        let showQA = Preferences.showQuickAccess
        if autoSave || (!showQA && !(item.isImage && Preferences.copyToClipboard)) {
            // Never lose a capture: if nothing else would surface it, save it.
            do { try FileStore.saveToUserFolder(item) } catch { ErrorPresenter.show(error, title: "Couldn't save capture") }
        }
        if showQA {
            QuickAccessController.shared.add(item)
        }
    }
}
