import AppKit

/// Background, padding, corner and shadow settings applied around the screenshot in the editor.
/// Lengths are in points and are multiplied by the document's pixel scale when drawn.
struct BackgroundStyle: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case none, solid, gradient, mesh
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "None"
            case .solid: return "Color"
            case .gradient: return "Gradient"
            case .mesh: return "Mesh"
            }
        }
    }

    /// Codable sRGB color.
    struct RGBA: Codable, Equatable {
        var r: Double, g: Double, b: Double, a: Double

        init(r: Double, g: Double, b: Double, a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        init(_ color: NSColor) {
            let c = color.usingColorSpace(.sRGB) ?? color
            self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
        }

        /// `#RRGGBB` convenience for presets.
        init(hex: UInt32) {
            self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
        }

        var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
        var cgColor: CGColor { nsColor.cgColor }
    }

    /// A linear gradient preset. `angle` follows the CSS convention: 0° points up, 90° points right.
    struct Gradient: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        var stops: [RGBA]
        var angle: Double
    }

    static let paddingRange: ClosedRange<CGFloat> = 0...200
    static let cornerRadiusRange: ClosedRange<CGFloat> = 0...64
    static let shadowBlurRange: ClosedRange<CGFloat> = 0...80

    var kind: Kind = .none
    var padding: CGFloat = 48
    var cornerRadius: CGFloat = 12
    var shadowEnabled = true
    var shadowBlur: CGFloat = 30
    var shadowOpacity: CGFloat = 0.45
    var solidColor = RGBA(hex: 0xF2F2F7)
    /// Preset id used by both the gradient and the mesh kinds.
    var gradientID: String = "sunset"

    var gradient: Gradient {
        Self.presets.first { $0.id == gradientID } ?? Self.presets[0]
    }

    static let presets: [Gradient] = [
        Gradient(id: "sunset", name: "Sunset", stops: [RGBA(hex: 0xFF9A8B), RGBA(hex: 0xFF6A88), RGBA(hex: 0xFF99AC)], angle: 135),
        Gradient(id: "ocean", name: "Ocean", stops: [RGBA(hex: 0x2E3192), RGBA(hex: 0x1BFFFF)], angle: 120),
        Gradient(id: "mint", name: "Mint", stops: [RGBA(hex: 0x43E97B), RGBA(hex: 0x38F9D7)], angle: 135),
        Gradient(id: "grape", name: "Grape", stops: [RGBA(hex: 0x667EEA), RGBA(hex: 0x764BA2)], angle: 135),
        Gradient(id: "graphite", name: "Graphite", stops: [RGBA(hex: 0x3A3D44), RGBA(hex: 0x1C1E22)], angle: 160),
        Gradient(id: "peach", name: "Peach", stops: [RGBA(hex: 0xFFECD2), RGBA(hex: 0xFCB69F)], angle: 120),
        Gradient(id: "aurora", name: "Aurora", stops: [RGBA(hex: 0x00C9FF), RGBA(hex: 0x92FE9D), RGBA(hex: 0xF9F586)], angle: 150),
        Gradient(id: "midnight", name: "Midnight", stops: [RGBA(hex: 0x0F2027), RGBA(hex: 0x203A43), RGBA(hex: 0x2C5364)], angle: 135),
    ]

    // MARK: Persistence

    static let defaultsKey = "editor.backgroundStyle"

    /// The style saved by the last editor session, or the default.
    static func load() -> BackgroundStyle {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let style = try? JSONDecoder().decode(BackgroundStyle.self, from: data) else { return BackgroundStyle() }
        return style.clamped()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func clamped() -> BackgroundStyle {
        var s = self
        s.padding = min(max(s.padding, Self.paddingRange.lowerBound), Self.paddingRange.upperBound)
        s.cornerRadius = min(max(s.cornerRadius, Self.cornerRadiusRange.lowerBound), Self.cornerRadiusRange.upperBound)
        s.shadowBlur = min(max(s.shadowBlur, Self.shadowBlurRange.lowerBound), Self.shadowBlurRange.upperBound)
        s.shadowOpacity = min(max(s.shadowOpacity, 0), 1)
        return s
    }
}

/// Pixel geometry of the exported composite: the background canvas and where the screenshot sits in it.
struct CompositeLayout: Equatable {
    /// Full output size in pixels (image + padding on every side).
    let canvasSize: CGSize
    /// Where the screenshot is drawn, in canvas pixels.
    let imageRect: CGRect

    init(imageSize: CGSize, style: BackgroundStyle, pixelScale: CGFloat) {
        let pad = (style.padding * pixelScale).rounded()
        imageRect = CGRect(x: pad, y: pad, width: imageSize.width, height: imageSize.height)
        canvasSize = CGSize(width: imageSize.width + pad * 2, height: imageSize.height + pad * 2)
    }

    /// Offset added to image coordinates to reach canvas coordinates.
    var imageOffset: CGPoint { imageRect.origin }
}
