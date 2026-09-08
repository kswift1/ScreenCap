import AppKit

/// Text / QR recognition on captured images. Stub: filled in by the OCR work stream.
@MainActor
final class OCRController {
    static let shared = OCRController()

    /// Recognizes text in `image`, copies it to the clipboard, and shows brief feedback near `sourceRect`.
    func recognizeAndCopy(image: CGImage, sourceRect: CGRect) async {
        NSLog("OCR not implemented yet")
    }
}
