import AppKit

/// Orchestrates every capture flow: permission → selection UI → ScreenCaptureKit → post-actions.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private(set) var history: [CaptureItem] = []
    private var selection: SelectionSession?
    /// Mode the All-in-One overlay opens in: whatever was used there last (this app session only).
    private var lastAllInOneMode: SelectionMode = .area

    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureFullscreen: captureFullscreen()
        case .captureArea: startSelection(mode: .area)
        case .captureWindow: startSelection(mode: .window)
        case .pinArea: startSelection(mode: .pin)
        case .toggleRecording: toggleRecording()
        case .openLastCapture: QuickAccessController.shared.showLast()
        case .recognizeText: startSelection(mode: .ocr)
        case .allInOne: startAllInOne()
        case .togglePins: PinController.shared.toggleHidden()
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
                finish(image: image, pixelScale: screen.backingScaleFactor, sourceRect: screen.frame)
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

    /// All-in-One (⇧⌘8): one overlay with a mode toolbar, starting in the last mode used there.
    private func startAllInOne() {
        startSelection(mode: lastAllInOneMode, allowsModeSwitch: true)
    }

    private func startSelection(mode: SelectionMode, allowsModeSwitch: Bool = false) {
        guard Permissions.ensureScreenCaptureAccess() else { return }
        if selection != nil {
            // Pressing the hotkey again while selecting cancels.
            cancelSelection()
            return
        }
        let session = SelectionSession(mode: mode, allowsModeSwitch: allowsModeSwitch) { [weak self] result, finalMode in
            guard let self else { return }
            self.selection = nil
            if allowsModeSwitch { self.lastAllInOneMode = finalMode }
            self.handle(result, mode: finalMode)
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
        if mode == .record, ScreenRecorder.shared.state.isActive, !result.isCancelled {
            // Record picked (e.g. from All-in-One) while already recording: stop instead of starting another.
            Task { await ScreenRecorder.shared.stop() }
            return
        }
        switch result {
        case .cancelled:
            return

        case .area(let screen, let rect):
            // `.fullscreen` arrives here as the whole display frame and is handled like any area.
            if mode == .record {
                Task { await ScreenRecorder.shared.start(screen: screen, rect: rect) }
            } else {
                Task {
                    do {
                        let image = try await CaptureEngine.captureDisplay(screen, rect: rect)
                        if mode == .pin {
                            pin(image: image, pixelScale: screen.backingScaleFactor, at: rect.intersection(screen.frame))
                        } else if mode == .ocr {
                            await OCRController.shared.recognizeAndCopy(image: image, sourceRect: rect)
                        } else {
                            finish(image: image, pixelScale: screen.backingScaleFactor, sourceRect: rect)
                        }
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
                        if mode == .pin {
                            pin(image: image, pixelScale: screen.backingScaleFactor, at: info.frame)
                        } else if mode == .ocr {
                            await OCRController.shared.recognizeAndCopy(image: image, sourceRect: info.frame)
                        } else {
                            finish(image: image, pixelScale: screen.backingScaleFactor, sourceRect: info.frame)
                        }
                    } catch {
                        ErrorPresenter.show(error, title: "Capture failed")
                    }
                }
            }
        }
    }

    // MARK: Post-capture

    func finish(image: CGImage, pixelScale: CGFloat, sourceRect: CGRect? = nil) {
        do {
            let item = try CaptureItem(image: image, pixelScale: pixelScale)
            item.sourceRect = sourceRect
            SoundPlayer.playCapture()
            if Preferences.copyToClipboard {
                Clipboard.copy(image: image, pixelScale: pixelScale)
            }
            publish(item)
        } catch {
            ErrorPresenter.show(error, title: "Couldn't save capture")
        }
    }

    /// Pin flow: the capture floats above everything at the spot it was taken from. Nothing else happens.
    func pin(image: CGImage, pixelScale: CGFloat, at rect: CGRect) {
        do {
            let item = try CaptureItem(image: image, pixelScale: pixelScale)
            item.sourceRect = rect
            history.append(item)
            SoundPlayer.playCapture()
            PinController.shared.pin(item, at: rect)
        } catch {
            ErrorPresenter.show(error, title: "Couldn't pin capture")
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

private extension SelectionResult {
    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
