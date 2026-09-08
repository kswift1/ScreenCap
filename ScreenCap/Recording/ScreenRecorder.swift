import AppKit
import ScreenCaptureKit
import AVFoundation

/// Records a region of a display to an .mp4 using SCStream + SCRecordingOutput (macOS 15+).
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()

    enum State: Equatable {
        case idle
        case starting
        case recording(started: Date)
        case stopping

        var isActive: Bool { self != .idle }
        var startDate: Date? { if case .recording(let d) = self { return d } else { return nil } }
    }

    @Published private(set) var state: State = .idle
    private(set) var region: CGRect = .zero

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var pixelScale: CGFloat = 2
    private var recordingFinished = false
    private var recordingError: Error?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var controls: RecordingControlsPanel?
    private var framePanel: RecordingFramePanel?

    func start(screen: NSScreen, rect: CGRect) async {
        guard state == .idle else { return }
        state = .starting
        do {
            let content = try await CaptureEngine.shareableContent()
            let filter = try CaptureEngine.displayFilter(for: screen, content: content)
            let scale = screen.backingScaleFactor
            let region = rect.intersection(screen.frame).integral
            let relative = region.relativeToTopLeft(of: screen)

            let config = SCStreamConfiguration()
            config.sourceRect = relative
            // H.264 wants even dimensions.
            config.width = max(2, Int(relative.width * scale) & ~1)
            config.height = max(2, Int(relative.height * scale) & ~1)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Preferences.recordFPS))
            config.showsCursor = Preferences.recordCursor
            config.capturesAudio = Preferences.recordAudio
            config.excludesCurrentProcessAudio = true
            config.queueDepth = 6
            config.pixelFormat = kCVPixelFormatType_32BGRA

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
            self.recordingOutput = output
            self.outputURL = url
            self.pixelScale = scale
            self.region = region
            self.recordingFinished = false
            self.recordingError = nil
            state = .recording(started: .now)
            showChrome(screen: screen, region: region)
        } catch {
            state = .idle
            ErrorPresenter.show(error, title: "Couldn't start recording")
        }
    }

    /// Stops the stream, waits for the file to finalize, then hands it to the coordinator.
    func stop(discard: Bool = false) async {
        guard case .recording = state, let stream else { return }
        state = .stopping
        hideChrome()

        do { try await stream.stopCapture() } catch { recordingError = recordingError ?? error }
        await waitForRecordingToFinish()

        let url = outputURL
        let error = recordingError
        self.stream = nil
        recordingOutput = nil
        outputURL = nil
        state = .idle

        guard let url else { return }
        if discard {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let error, !FileManager.default.fileExists(atPath: url.path) {
            ErrorPresenter.show(error, title: "Recording failed")
            return
        }
        SoundPlayer.playCapture()
        CaptureCoordinator.shared.recordingFinished(url: url, pixelScale: pixelScale)
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
            guard case .recording = self.state else { return }
            self.recordingError = error
            await self.stop()
        }
    }
}

extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.recordingError = error
            self.resumeFinish()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeFinish() }
    }
}
