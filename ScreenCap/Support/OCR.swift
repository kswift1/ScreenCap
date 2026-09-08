import AppKit
import Vision

/// Text / QR recognition on captured images. Recognition runs off the main thread; everything
/// that touches UI (clipboard, sound, HUD) runs on the main actor.
@MainActor
final class OCRController {
    static let shared = OCRController()

    /// Languages we ask Vision for, in priority order. Filtered against what the OS supports at runtime.
    private static let preferredLanguages = ["ko-KR", "en-US", "ja-JP", "zh-Hans"]

    // MARK: Capture flow

    /// Recognizes text in `image`, copies it to the clipboard, and shows brief feedback near `sourceRect`
    /// (Cocoa screen coordinates). Falls back to QR / barcode payloads when no text is found. Never throws.
    func recognizeAndCopy(image: CGImage, sourceRect: CGRect) async {
        do {
            async let textTask = recognizeText(in: image)
            async let barcodeTask = detectBarcodes(in: image)
            let text = try await textTask
            // A barcode failure should not hide perfectly good text.
            let barcodes = (try? await barcodeTask) ?? []
            present(text: text, barcodes: barcodes, near: sourceRect)
        } catch {
            NSLog("OCR failed: \(error)")
            OCRResultHUD.shared.show(
                .init(symbol: "exclamationmark.triangle", title: "Text recognition failed",
                      detail: error.localizedDescription, openURL: nil),
                near: sourceRect)
        }
    }

    /// Picks what to copy (text first, then barcode payloads), copies it, and shows the HUD.
    private func present(text: String, barcodes: [String], near sourceRect: CGRect) {
        let payload: String
        let title: String
        if !text.isEmpty {
            payload = text
            let count = text.split(separator: "\n", omittingEmptySubsequences: true).count
            title = "Copied \(count) \(count == 1 ? "line" : "lines")"
        } else if !barcodes.isEmpty {
            payload = barcodes.joined(separator: "\n")
            title = barcodes.count == 1 ? "Copied QR code" : "Copied \(barcodes.count) codes"
        } else {
            OCRResultHUD.shared.show(
                .init(symbol: "text.viewfinder", title: "No text found", detail: nil, openURL: nil),
                near: sourceRect)
            return
        }

        Clipboard.copy(text: payload)
        SoundPlayer.playCapture()

        let firstLine = payload.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let openURL = Self.url(in: text.isEmpty ? barcodes : [payload])
        OCRResultHUD.shared.show(
            .init(symbol: openURL == nil ? "doc.on.clipboard" : "qrcode.viewfinder",
                  title: title, detail: firstLine, openURL: openURL),
            near: sourceRect)
    }

    /// First candidate that is a complete web URL, if any. Whole-text candidates must be a single token.
    private static func url(in candidates: [String]) -> URL? {
        for raw in candidates {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, !s.contains(where: \.isWhitespace),
                  let url = URL(string: s), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host != nil else { continue }
            return url
        }
        return nil
    }

    // MARK: Reusable API

    /// Recognizes text in `image` and returns it with the original line / paragraph layout preserved.
    /// Returns an empty string when nothing was recognized.
    func recognizeText(in image: CGImage) async throws -> String {
        let observations = try await Self.performOffMain { () throws -> [VNRecognizedTextObservation] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = Self.recognitionLanguages(for: request)
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return request.results ?? []
        }
        return OCRLayout.text(from: observations)
    }

    /// Detects QR codes and barcodes in `image` and returns their string payloads (deduplicated, top-to-bottom).
    func detectBarcodes(in image: CGImage) async throws -> [String] {
        try await Self.performOffMain { () throws -> [String] in
            let request = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let sorted = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            var seen = Set<String>()
            return sorted.compactMap { obs in
                guard let s = obs.payloadStringValue, !s.isEmpty, seen.insert(s).inserted else { return nil }
                return s
            }
        }
    }

    // MARK: Helpers

    /// Preferred languages that this OS version can actually recognize, in preference order.
    nonisolated private static func recognitionLanguages(for request: VNRecognizeTextRequest) -> [String] {
        guard let supported = try? request.supportedRecognitionLanguages() else { return ["en-US"] }
        let picked = preferredLanguages.filter { supported.contains($0) }
        return picked.isEmpty ? Array(supported.prefix(1)) : picked
    }

    /// Runs `work` on a detached background task so Vision never blocks the main thread.
    nonisolated private static func performOffMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}

// MARK: - Layout reconstruction

/// Turns Vision text observations back into lines and paragraphs. Vision boxes are normalized with a
/// bottom-left origin, so `y` is flipped here to make "top-to-bottom" sorting natural.
enum OCRLayout {
    /// One recognized fragment in top-left-origin normalized coordinates.
    struct Fragment {
        var text: String
        var minX: CGFloat
        var maxX: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var midY: CGFloat { (top + bottom) / 2 }
        var height: CGFloat { bottom - top }
    }

    /// A reconstructed line: fragments sharing (roughly) the same baseline.
    private struct Line {
        var fragments: [Fragment]
        var top: CGFloat
        var bottom: CGFloat
        /// Mean centre of the fragments (not the union box), so one tall glyph doesn't drag the baseline.
        var midY: CGFloat { fragments.map(\.midY).reduce(0, +) / CGFloat(fragments.count) }
    }

    static func text(from observations: [VNRecognizedTextObservation]) -> String {
        let fragments = observations.compactMap { obs -> Fragment? in
            guard let best = obs.topCandidates(1).first else { return nil }
            let s = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            let box = obs.boundingBox
            return Fragment(text: s, minX: box.minX, maxX: box.maxX, top: 1 - box.maxY, bottom: 1 - box.minY)
        }
        return text(from: fragments)
    }

    /// Merges fragments whose vertical centres are within half a line height, then joins lines,
    /// inserting a blank line wherever the vertical gap exceeds 1.5 line heights.
    static func text(from fragments: [Fragment]) -> String {
        guard !fragments.isEmpty else { return "" }
        let lineHeight = medianHeight(of: fragments)
        var lines: [Line] = []
        for frag in fragments.sorted(by: { $0.midY < $1.midY }) {
            if var last = lines.last, abs(frag.midY - last.midY) <= lineHeight * 0.5 {
                last.fragments.append(frag)
                last.top = min(last.top, frag.top)
                last.bottom = max(last.bottom, frag.bottom)
                lines[lines.count - 1] = last
            } else {
                lines.append(Line(fragments: [frag], top: frag.top, bottom: frag.bottom))
            }
        }

        var out: [String] = []
        var previous: Line?
        for line in lines {
            if let prev = previous, line.top - prev.bottom > lineHeight * 1.5 {
                out.append("")
            }
            out.append(line.fragments.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: " "))
            previous = line
        }
        return out.joined(separator: "\n")
    }

    private static func medianHeight(of fragments: [Fragment]) -> CGFloat {
        let heights = fragments.map(\.height).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return 0.02 }
        return heights[heights.count / 2]
    }
}

extension Clipboard {
    /// Copies plain text, replacing the current clipboard contents.
    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
