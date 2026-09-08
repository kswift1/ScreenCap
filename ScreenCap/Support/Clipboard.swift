import AppKit

enum Clipboard {
    static func copy(image: CGImage, pixelScale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let png = image.encoded(as: .png, pixelScale: pixelScale) {
            item.setData(png, forType: .png)
        }
        if let tiff = image.nsImage.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pb.writeObjects([item])
    }

    static func copy(fileURL: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
    }
}

enum SoundPlayer {
    private static let captureSound: NSSound? = {
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let s = NSSound(contentsOfFile: path, byReference: true) { return s }
        }
        return NSSound(named: "Tink")
    }()

    static func playCapture() {
        guard Preferences.playSound else { return }
        captureSound?.stop()
        captureSound?.play()
    }
}
