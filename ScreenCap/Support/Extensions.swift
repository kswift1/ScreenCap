import AppKit
import UniformTypeIdentifiers

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Height of the primary display; needed to flip between Cocoa (bottom-left) and CG (top-left) coordinates.
    static var primaryHeight: CGFloat { screens.first?.frame.height ?? 0 }

    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(p) } ?? main ?? screens[0]
    }

    static func containing(_ rect: CGRect) -> NSScreen {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return screens.first { $0.frame.contains(center) }
            ?? screens.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
            ?? underMouse
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    /// Rectangle spanning two arbitrary corner points.
    init(corner a: CGPoint, corner b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Cocoa screen rect → rect relative to a screen's top-left origin (what ScreenCaptureKit wants).
    func relativeToTopLeft(of screen: NSScreen) -> CGRect {
        CGRect(x: minX - screen.frame.minX, y: screen.frame.maxY - maxY, width: width, height: height)
    }

    /// CG global (top-left origin) → Cocoa global (bottom-left origin).
    static func cocoaRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: NSScreen.primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }

    /// Shortest distance from this point to the segment a-b.
    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / lenSq))
        return distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpg
    var id: String { rawValue }
    var utType: UTType { self == .png ? .png : .jpeg }
    var fileExtension: String { rawValue }
    var title: String { self == .png ? "PNG" : "JPEG" }
}

extension CGImage {
    /// Encode to PNG/JPEG with a DPI tag so Preview shows the logical (point) size for Retina captures.
    func encoded(as format: ImageFormat, pixelScale: CGFloat, quality: CGFloat = 0.9) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * pixelScale,
            kCGImagePropertyDPIHeight: 72 * pixelScale,
        ]
        if format == .jpg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, self, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func load(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    var nsImage: NSImage { NSImage(cgImage: self, size: NSSize(width: width, height: height)) }
}

extension NSColor {
    var cg: CGColor { cgColor }
}

extension Notification.Name {
    static let hotkeysDidChange = Notification.Name("ScreenCap.hotkeysDidChange")
}
