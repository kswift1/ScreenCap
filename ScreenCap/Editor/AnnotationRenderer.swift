import AppKit
import CoreText

/// Draws annotations into any CGContext whose coordinate system is y-down image pixels.
/// The same code path renders the live canvas and the exported image.
enum AnnotationRenderer {
    /// Draws a CGImage in a y-down context without flipping it.
    static func drawImage(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    static func draw(_ a: Annotation, in ctx: CGContext, pixelScale s: CGFloat, pixelated: CGImage?, imageSize: CGSize) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = a.style.color.cgColor
        let lw = a.style.lineWidth * s
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lw)

        switch a.shape {
        case .line(let from, let to):
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

        case .arrow(let from, let to):
            drawArrow(from: from, to: to, lineWidth: lw, in: ctx)

        case .rect(let r):
            ctx.stroke(r.insetBy(dx: lw / 2, dy: lw / 2))

        case .ellipse(let r):
            ctx.strokeEllipse(in: r.insetBy(dx: lw / 2, dy: lw / 2))

        case .pen(let pts):
            addSmoothPath(pts, to: ctx)
            ctx.strokePath()

        case .highlighter(let pts):
            // Plain alpha (not multiply) so it stays visible on dark screenshots too.
            ctx.setStrokeColor(a.style.color.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(max(lw * 3.5, 14 * s))
            ctx.setLineCap(.square)
            addSmoothPath(pts, to: ctx)
            ctx.strokePath()

        case .blur(let r):
            guard let pixelated else { return }
            ctx.clip(to: r)
            drawImage(pixelated, in: CGRect(origin: .zero, size: imageSize), context: ctx)

        case .number(let n, let center):
            let radius = numberRadius(style: a.style, pixelScale: s)
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.setShadow(offset: CGSize(width: 0, height: 1 * s), blur: 3 * s, color: CGColor(gray: 0, alpha: 0.35))
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let font = NSFont.systemFont(ofSize: radius * 1.1, weight: .bold)
            let str = NSAttributedString(string: "\(n)", attributes: [.font: font, .foregroundColor: NSColor.white])
            let line = CTLineCreateWithAttributedString(str)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.saveGState()
            ctx.translateBy(x: center.x - bounds.width / 2 - bounds.minX, y: center.y + bounds.height / 2 + bounds.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()

        case .text(let string, let origin):
            drawText(string, origin: origin, style: a.style, pixelScale: s, in: ctx)
        }
    }

    // MARK: Geometry shared with hit-testing

    static func numberRadius(style: AnnotationStyle, pixelScale s: CGFloat) -> CGFloat {
        max(12, style.fontSize * 0.6) * s
    }

    static func font(for style: AnnotationStyle, pixelScale s: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: style.fontSize * s, weight: .semibold)
    }

    /// Bounding box of a text annotation in image pixels.
    static func textBounds(_ string: String, origin: CGPoint, style: AnnotationStyle, pixelScale s: CGFloat) -> CGRect {
        let font = font(for: style, pixelScale: s)
        let lines = string.components(separatedBy: "\n")
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        var width: CGFloat = 0
        for l in lines {
            let attr = NSAttributedString(string: l.isEmpty ? " " : l, attributes: [.font: font])
            width = max(width, CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
        }
        return CGRect(x: origin.x, y: origin.y, width: CGFloat(width), height: lineHeight * CGFloat(lines.count))
    }

    private static func drawText(_ string: String, origin: CGPoint, style: AnnotationStyle, pixelScale s: CGFloat, in ctx: CGContext) {
        let font = font(for: style, pixelScale: s)
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        ctx.setShadow(offset: CGSize(width: 0, height: 1 * s), blur: 2 * s, color: CGColor(gray: 0, alpha: 0.4))
        for (i, l) in string.components(separatedBy: "\n").enumerated() where !l.isEmpty {
            let attr = NSAttributedString(string: l, attributes: [.font: font, .foregroundColor: style.color])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y + CGFloat(i) * lineHeight + font.ascender)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, lineWidth lw: CGFloat, in ctx: CGContext) {
        let length = from.distance(to: to)
        guard length > 0.1 else { return }
        let headLength = min(length, max(lw * 3.2, 14))
        let headWidth = headLength * 0.85
        let dx = (to.x - from.x) / length, dy = (to.y - from.y) / length
        let base = CGPoint(x: to.x - dx * headLength, y: to.y - dy * headLength)
        let nx = -dy, ny = dx

        ctx.move(to: from)
        ctx.addLine(to: CGPoint(x: to.x - dx * headLength * 0.7, y: to.y - dy * headLength * 0.7))
        ctx.strokePath()

        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: base.x + nx * headWidth / 2, y: base.y + ny * headWidth / 2))
        ctx.addLine(to: CGPoint(x: base.x - nx * headWidth / 2, y: base.y - ny * headWidth / 2))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func addSmoothPath(_ pts: [CGPoint], to ctx: CGContext) {
        guard let first = pts.first else { return }
        ctx.move(to: first)
        if pts.count == 1 { ctx.addLine(to: first); return }
        if pts.count == 2 { ctx.addLine(to: pts[1]); return }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            ctx.addQuadCurve(to: mid, control: pts[i])
        }
        ctx.addLine(to: pts[pts.count - 1])
    }

    // MARK: Hit testing

    static func bounds(of a: Annotation, pixelScale s: CGFloat) -> CGRect {
        let lw = a.style.lineWidth * s
        switch a.shape {
        case .arrow(let p, let q), .line(let p, let q):
            return CGRect(corner: p, corner: q).insetBy(dx: -lw * 2, dy: -lw * 2)
        case .rect(let r), .ellipse(let r), .blur(let r):
            return r
        case .pen(let pts), .highlighter(let pts):
            guard let f = pts.first else { return .zero }
            var r = CGRect(origin: f, size: .zero)
            for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -lw * 2, dy: -lw * 2)
        case .text(let str, let o):
            return textBounds(str, origin: o, style: a.style, pixelScale: s)
        case .number(_, let c):
            let r = numberRadius(style: a.style, pixelScale: s)
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        }
    }

    static func hitTest(_ a: Annotation, point p: CGPoint, pixelScale s: CGFloat) -> Bool {
        let tolerance = max(8 * s, a.style.lineWidth * s)
        switch a.shape {
        case .arrow(let a, let b), .line(let a, let b):
            return p.distance(toSegment: a, b) <= tolerance
        case .pen(let pts):
            return zip(pts, pts.dropFirst()).contains { p.distance(toSegment: $0, $1) <= tolerance }
        case .highlighter(let pts):
            return zip(pts, pts.dropFirst()).contains { p.distance(toSegment: $0, $1) <= tolerance * 2 }
        default:
            return bounds(of: a, pixelScale: s).insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p)
        }
    }
}
