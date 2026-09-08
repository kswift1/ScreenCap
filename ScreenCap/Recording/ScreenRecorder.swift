import AppKit
import ScreenCaptureKit
import AVFoundation

/// Records a region of a display to an .mp4 using SCStream + SCRecordingOutput (macOS 15+).
///
/// SCStream has no pause API, so "pause" ends the current segment file and "resume" starts a
/// fresh stream into a new one; `stop()` joins the segments with `RecordingSegmentJoiner`.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()

    enum State: Equatable {
        case idle
        case countingDown
        case starting
        case recording(started: Date)
        case paused
        case stopping

        var isActive: Bool { self != .idle }
        var isRecording: Bool { if case .recording = self { return true } else { return false } }
        var isPaused: Bool { self == .paused }
        var canPauseOrResume: Bool { isRecording || isPaused }
    }

    @Published private(set) var state: State = .idle
    private(set) var region: CGRect = .zero

    /// Total recorded time of finished segments (paused time is never counted).
    private var completedDuration: TimeInterval = 0

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var segments: [URL] = []
    private var pixelScale: CGFloat = 2
    private var recordingFinished = false
    private var recordingError: Error?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var controls: RecordingControlsPanel?
    private var framePanel: RecordingFramePanel?
    private var countdownPanel: RecordingCountdownPanel?

    // Kept so a resumed segment can rebuild an identical stream.
    private var streamFilter: SCContentFilter?
    private var streamConfig: SCStreamConfiguration?

    /// Recorded time so far, excluding pauses.
    func elapsed(at date: Date) -> TimeInterval {
        if case .recording(let started) = state {
            return completedDuration + max(0, date.timeIntervalSince(started))
        }
        return completedDuration
    }

    func start(screen: NSScreen, rect: CGRect) async {
        guard state == .idle else { return }
        state = .countingDown
        completedDuration = 0
        segments = []
        recordingError = nil

        var useMicrophone = false
        if Preferences.recordMicrophone { useMicrophone = await MicrophoneAccess.request() }

        let region = rect.intersection(screen.frame).integral
        guard await runCountdown(seconds: Preferences.recordCountdown, screen: screen, region: region) else {
            state = .idle
            return
        }

        state = .starting
        do {
            let content = try await CaptureEngine.shareableContent()
            let filter = try CaptureEngine.displayFilter(for: screen, content: content)
            let config = makeConfiguration(screen: screen, region: region, microphone: useMicrophone)
            streamFilter = filter
            streamConfig = config
            pixelScale = screen.backingScaleFactor
            self.region = region

            try await startSegment()
            showChrome(screen: screen, region: region)
        } catch {
            clearStreamState()
            state = .idle
            ErrorPresenter.show(error, title: "Couldn't start recording")
        }
    }

    /// Ends the current segment and keeps the chrome on screen; `resume()` starts the next one.
    func pause() async {
        guard case .recording = state else { return }
        state = .stopping
        await finishCurrentSegment()
        state = .paused
    }

    func resume() async {
        guard state == .paused else { return }
        state = .starting
        do {
            try await startSegment()
        } catch {
            recordingError = error
            state = .paused
            ErrorPresenter.show(error, title: "Couldn't resume recording")
        }
    }

    func togglePause() async {
        if state.isPaused { await resume() } else { await pause() }
    }

    /// Stops the stream, waits for the file to finalize, joins segments, then hands the result to the coordinator.
    func stop(discard: Bool = false) async {
        switch state {
        case .countingDown:
            cancelCountdown()
            return
        case .recording, .paused:
            break
        default:
            return
        }
        state = .stopping
        hideChrome()

        if stream != nil { await finishCurrentSegment() }

        let urls = segments
        let error = recordingError
        let scale = pixelScale
        clearStreamState()
        state = .idle

        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if discard {
            existing.forEach { try? FileManager.default.removeItem(at: $0) }
            return
        }
        if existing.isEmpty {
            if let error { ErrorPresenter.show(error, title: "Recording failed") }
            return
        }

        let url: URL
        if existing.count == 1 {
            url = existing[0]
        } else {
            let joined = FileStore.temporaryURL(ext: "mp4")
            do {
                try await RecordingSegmentJoiner.join(existing, to: joined)
                existing.forEach { try? FileManager.default.removeItem(at: $0) }
                url = joined
            } catch {
                // Never lose footage: hand over the segments as separate recordings.
                ErrorPresenter.show(error, title: "Couldn't join recording segments")
                SoundPlayer.playCapture()
                existing.forEach { CaptureCoordinator.shared.recordingFinished(url: $0, pixelScale: scale) }
                return
            }
        }
        SoundPlayer.playCapture()
        CaptureCoordinator.shared.recordingFinished(url: url, pixelScale: scale)
    }

    // MARK: Segments

    private func makeConfiguration(screen: NSScreen, region: CGRect, microphone: Bool) -> SCStreamConfiguration {
        let scale = screen.backingScaleFactor
        let relative = region.relativeToTopLeft(of: screen)
        let config = SCStreamConfiguration()
        config.sourceRect = relative
        // H.264 wants even dimensions.
        config.width = max(2, Int(relative.width * scale) & ~1)
        config.height = max(2, Int(relative.height * scale) & ~1)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Preferences.recordFPS))
        config.showsCursor = Preferences.recordCursor
        config.showMouseClicks = Preferences.recordClickHighlight
        config.capturesAudio = Preferences.recordAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = microphone
        config.microphoneCaptureDeviceID = nil // system default input
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }

    /// Creates a stream + recording output for a new segment file and starts capturing.
    private func startSegment() async throws {
        guard let filter = streamFilter, let config = streamConfig else { throw CaptureError.displayNotFound }
        let url = FileStore.temporaryURL(ext: "mp4")
        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.videoCodecType = .h264
        recConfig.outputFileType = .mp4
        let output = SCRecordingOutput(configuration: recConfig, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()

        self.stream = stream
        recordingOutput = output
        outputURL = url
        recordingFinished = false
        state = .recording(started: .now)
    }

    /// Stops the live stream, waits for its file to finalize, and books the segment.
    private func finishCurrentSegment() async {
        guard let stream else { return }
        if case .recording(let started) = state {
            completedDuration += max(0, Date.now.timeIntervalSince(started))
        }
        do { try await stream.stopCapture() } catch { recordingError = recordingError ?? error }
        await waitForRecordingToFinish()
        if let outputURL { segments.append(outputURL) }
        self.stream = nil
        recordingOutput = nil
        outputURL = nil
    }

    private func clearStreamState() {
        stream = nil
        recordingOutput = nil
        outputURL = nil
        segments = []
        streamFilter = nil
        streamConfig = nil
    }

    private func waitForRecordingToFinish() async {
        if recordingFinished { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finishContinuation = c
            // Safety net: don't hang forever if the delegate never fires.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self.resumeFinish()
            }
        }
    }

    private func resumeFinish() {
        recordingFinished = true
        finishContinuation?.resume()
        finishContinuation = nil
    }

    // MARK: Countdown

    /// Shows the countdown over the recording region. Returns false if it was cancelled (Esc or hotkey).
    private func runCountdown(seconds: Int, screen: NSScreen, region: CGRect) async -> Bool {
        guard seconds > 0 else { return true }
        let panel = RecordingCountdownPanel(screen: screen, region: region) { [weak self] in
            self?.cancelCountdown()
        }
        panel.makeKeyAndOrderFront(nil)
        countdownPanel = panel

        let task = Task { @MainActor in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                panel.show(remaining)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
        }
        countdownTask = task
        await task.value
        let cancelled = task.isCancelled
        countdownTask = nil
        countdownPanel = nil
        panel.orderOut(nil)
        return !cancelled
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
    }

    // MARK: On-screen chrome (frame + controls)

    private func showChrome(screen: NSScreen, region: CGRect) {
        let frame = RecordingFramePanel(region: region)
        frame.orderFrontRegardless()
        framePanel = frame

        let controls = RecordingControlsPanel(recorder: self, screen: screen)
        controls.orderFrontRegardless()
        self.controls = controls
    }

    private func hideChrome() {
        framePanel?.orderOut(nil)
        framePanel = nil
        controls?.orderOut(nil)
        controls = nil
    }
}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard case .recording = self.state, stream === self.stream else { return }
            self.recordingError = error
            await self.stop()
        }
    }
}

extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            guard recordingOutput === self.recordingOutput else { return }
            self.recordingError = error
            self.resumeFinish()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard recordingOutput === self.recordingOutput else { return }
            self.resumeFinish()
        }
    }
}

/// Microphone permission for recordings that include the mic.
enum MicrophoneAccess {
    /// Returns true when access is (or becomes) granted. On denial explains where to enable it.
    @MainActor
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return true }
        default:
            break
        }
        presentDeniedAlert()
        return false
    }

    @MainActor
    private static func presentDeniedAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Microphone access is off"
        alert.informativeText = "ScreenCap can't record your microphone until you allow it in System Settings → Privacy & Security → Microphone. This recording will continue without the microphone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Record Without Microphone")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
