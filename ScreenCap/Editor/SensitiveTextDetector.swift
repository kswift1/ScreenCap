import AppKit
import Vision

/// Finds text that probably shouldn't ship in a screenshot (emails, phone numbers, IPv4 addresses,
/// API-key-like tokens) and returns where it sits so the editor can propose Pixelate rectangles.
enum SensitiveTextDetector {
    enum Kind: String, CaseIterable, Sendable {
        case email, phone, ipAddress, apiKey

        var title: String {
            switch self {
            case .email: return "Email"
            case .phone: return "Phone"
            case .ipAddress: return "IP address"
            case .apiKey: return "API key"
            }
        }

        var symbol: String {
            switch self {
            case .email: return "envelope"
            case .phone: return "phone"
            case .ipAddress: return "network"
            case .apiKey: return "key"
            }
        }
    }

    /// One whitespace-separated token of a recognized line with its box in image pixels (top-left origin).
    struct Word: Sendable {
        var string: String
        /// Where the token sits in its line's string.
        var range: Range<String.Index>
        var boundingBox: CGRect
    }

    /// One recognized line: the full string, its box, and per-word boxes.
    struct Line: Sendable {
        var string: String
        var boundingBox: CGRect
        var words: [Word]
    }

    /// A proposed redaction.
    struct Proposal: Identifiable, Sendable {
        let id = UUID()
        var kind: Kind
        var text: String
        /// Image-pixel rect (top-left origin) to pixelate.
        var rect: CGRect
    }

    // MARK: OCR with boxes

    /// Runs Vision's text recognizer directly (the shared OCRController only returns plain text) and
    /// returns every line with (string, boundingBox) pairs for the line and for each of its words.
    static func recognizeLines(in image: CGImage) async throws -> [Line] {
        let size = CGSize(width: image.width, height: image.height)
        return try await Task.detached(priority: .userInitiated) { () throws -> [Line] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false // keeps identifiers and tokens verbatim
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap { obs -> Line? in
                guard let best = obs.topCandidates(1).first, !best.string.isEmpty else { return nil }
                let words = tokenRanges(in: best.string).compactMap { range -> Word? in
                    guard let box = try? best.boundingBox(for: range)?.boundingBox else { return nil }
                    return Word(string: String(best.string[range]), range: range, boundingBox: pixelRect(box, in: size))
                }
                return Line(string: best.string, boundingBox: pixelRect(obs.boundingBox, in: size), words: words)
            }
        }.value
    }

    /// Recognizes text, then proposes one pixelate rect per sensitive match, padded by 2 pt.
    static func detect(in image: CGImage, pixelScale: CGFloat) async throws -> [Proposal] {
        let lines = try await recognizeLines(in: image)
        var proposals: [Proposal] = []
        for line in lines {
            for match in matches(in: line.string) {
                // Union of the word boxes the match touches; the whole line if Vision gave no word boxes.
                let boxes = line.words.filter { $0.range.overlaps(match.range) }.map(\.boundingBox)
                let rect = boxes.dropFirst().reduce(boxes.first ?? line.boundingBox) { $0.union($1) }
                proposals.append(Proposal(kind: match.kind, text: match.text,
                                          rect: rect.insetBy(dx: -2 * pixelScale, dy: -2 * pixelScale)))
            }
        }
        return proposals.sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
    }

    // MARK: Matching

    struct Match: Equatable {
        var kind: Kind
        var text: String
        var range: Range<String.Index>
    }

    private static let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
    private static let ipv4 = try! NSRegularExpression(
        pattern: #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])"#)
    private static let phone = try! NSRegularExpression(
        pattern: #"(?<![\w.\-])(?:\+\d{1,3}[\s.\-]?)?(?:\(\d{2,4}\)|\d{2,4})[\s.\-]?\d{3,4}[\s.\-]?\d{4}(?![\w])"#)
    private static let prefixedKey = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_\-])(?:sk-[A-Za-z0-9_\-]{8,}|ghp_[A-Za-z0-9_]{8,}|AKIA[A-Z0-9]{12,})"#)
    private static let longToken = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{20,}(?![A-Za-z0-9_\-])"#)

    /// Sensitive substrings of `s`, non-overlapping, in priority order (email > IP > key > phone).
    static func matches(in s: String) -> [Match] {
        var found: [Match] = []
        func scan(_ re: NSRegularExpression, _ kind: Kind, accept: (String) -> Bool = { _ in true }) {
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(m.range, in: s) else { continue }
                let text = String(s[range])
                guard accept(text), !found.contains(where: { $0.range.overlaps(range) }) else { continue }
                found.append(Match(kind: kind, text: text, range: range))
            }
        }
        scan(email, .email)
        scan(ipv4, .ipAddress)
        scan(prefixedKey, .apiKey)
        // A generic long token must mix letters and digits, otherwise long words and identifiers would match.
        scan(longToken, .apiKey) { t in t.contains(where: \.isNumber) && t.contains(where: \.isLetter) }
        scan(phone, .phone) { t in (9...15).contains(t.filter(\.isNumber).count) }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Helpers

    /// Whitespace-separated token ranges of `s`.
    static func tokenRanges(in s: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isWhitespace {
                if let st = start { out.append(st..<i); start = nil }
            } else if start == nil {
                start = i
            }
            i = s.index(after: i)
        }
        if let st = start { out.append(st..<s.endIndex) }
        return out
    }

    /// Vision boxes are normalized with a bottom-left origin; convert to top-left pixel coordinates.
    private static func pixelRect(_ box: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
               width: box.width * size.width, height: box.height * size.height)
    }
}
