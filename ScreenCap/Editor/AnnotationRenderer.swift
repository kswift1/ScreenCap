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

    // MARK: Composite (background + screenshot + annotations)

    /// Everything the exported image contains, drawn into a y-down context whose origin is the
    /// top-left of the composite canvas (see `CompositeLayout`). The live canvas and `render()`
    /// both call this so the preview matches the export exactly.
    ///
    /// - Parameter shadowScale: CG shadows are specified in the context's base space, not user
    ///   space, so callers pass the CTM scale in effect (1 for a bitmap, the zoom for the canvas).
    static func drawComposite(image: CGImage, annotations: [Annotation], pixelated: CGImage?,
                              background: BackgroundStyle, layout: CompositeLayout, pixelScale s: CGFloat,
                              shadowScale: CGFloat, in ctx: CGContext) {
        drawBackground(background, in: CGRect(origin: .zero, size: layout.canvasSize), pixelScale: s, context: ctx)
        drawScreenshot(image, in: layout.imageRect, style: background, pixelScale: s, shadowScale: shadowScale, context: ctx)

        guard !annotations.isEmpty else { return }
        ctx.saveGState()
        ctx.addPath(screenshotPath(in: layout.imageRect, style: background, pixelScale: s))
        ctx.clip()
        ctx.translateBy(x: layout.imageOffset.x, y: layout.imageOffset.y)
        let imageSize = layout.imageRect.size
        // All spotlights share one dim layer (drawn beneath the other annotations) so they never double-dim.
        let spotlights = annotations.filter(\.isSpotlight)
        if !spotlights.isEmpty {
            drawSpotlights(spotlights, imageSize: imageSize, in: ctx)
        }
        for a in annotations where !a.isSpotlight {
            draw(a, in: ctx, pixelScale: s, pixelated: pixelated, imageSize: imageSize)
        }
        ctx.restoreGState()
    }

    // MARK: Spotlight

    /// Dim opacity for the line-width picker: thicker "line" = stronger dim (4 pt → the default 55%).
    static func spotlightDimAlpha(lineWidth: CGFloat) -> CGFloat {
        switch lineWidth {
        case ..<3: return 0.35
        case ..<5: return 0.55
        case ..<7: return 0.68
        case ..<10: return 0.8
        default: return 0.9
        }
    }

    /// Fills the whole image with the dim colour except inside the spotlight shapes, in one pass: the
    /// dim fill and the holes go into a single transparency layer, so several spotlights never stack
    /// and overlapping ones are simply unioned. Colour and strength come from the most recent spotlight.
    static func drawSpotlights(_ spots: [Annotation], imageSize: CGSize, in ctx: CGContext) {
        guard let last = spots.last else { return }
        let alpha = spotlightDimAlpha(lineWidth: last.style.lineWidth)
        let color = last.style.color.withAlphaComponent(alpha).cgColor
        let full = CGRect(origin: .zero, size: imageSize)
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color)
        ctx.fill(full)
        ctx.setBlendMode(.clear)
        let holes = CGMutablePath()
        for a in spots {
            guard case .spotlight(let r, let ellipse) = a.shape else { continue }
            if ellipse { holes.addEllipse(in: r) } else { holes.addRect(r) }
        }
        ctx.addPath(holes)
        ctx.fillPath(using: .winding)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Rounded-rect outline of the screenshot in canvas pixels.
    static func screenshotPath(in rect: CGRect, style: BackgroundStyle, pixelScale s: CGFloat) -> CGPath {
        let radius = min(style.cornerRadius * s, min(rect.width, rect.height) / 2)
        return radius > 0 ? CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil) : CGPath(rect: rect, transform: nil)
    }

    /// Fills `rect` with the chosen background (nothing for `.none`, leaving it transparent).
    static func drawBackground(_ style: BackgroundStyle, in rect: CGRect, pixelScale s: CGFloat, context ctx: CGContext) {
        switch style.kind {
        case .none:
            return
        case .solid:
            ctx.saveGState()
            ctx.setFillColor(style.solidColor.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
        case .gradient:
            drawLinearGradient(style.gradient, in: rect, context: ctx)
        case .mesh:
            drawMeshGradient(style.gradient, in: rect, context: ctx)
        }
    }

    /// The screenshot with rounded corners and an optional drop shadow.
    static func drawScreenshot(_ image: CGImage, in rect: CGRect, style: BackgroundStyle, pixelScale s: CGFloat,
                               shadowScale: CGFloat, context ctx: CGContext) {
        let path = screenshotPath(in: rect, style: style, pixelScale: s)
        if style.shadowEnabled && style.shadowBlur > 0 && style.shadowOpacity > 0 {
            ctx.saveGState()
            // Base space is y-up, so a negative y offset moves the shadow down on screen.
            ctx.setShadow(offset: CGSize(width: 0, height: -style.shadowBlur * 0.35 * s * shadowScale),
                          blur: style.shadowBlur * s * shadowScale,
                          color: CGColor(gray: 0, alpha: style.shadowOpacity))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        drawImage(image, in: rect, context: ctx)
        ctx.restoreGState()
    }

    private static func cgGradient(_ g: BackgroundStyle.Gradient) -> CGGradient? {
        let colors = g.stops.map(\.cgColor) as CFArray
        let n = max(g.stops.count - 1, 1)
        let locations = g.stops.indices.map { CGFloat($0) / CGFloat(n) }
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations)
    }

    private static func drawLinearGradient(_ g: BackgroundStyle.Gradient, in rect: CGRect, context ctx: CGContext) {
        guard let gradient = cgGradient(g) else { return }
        // CSS angle: 0° = towards the top, 90° = towards the right (y-down space).
        let rad = g.angle * .pi / 180
        let dir = CGVector(dx: sin(rad), dy: -cos(rad))
        let half = (abs(rect.width * dir.dx) + abs(rect.height * dir.dy)) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let start = CGPoint(x: c.x - dir.dx * half, y: c.y - dir.dy * half)
        let end = CGPoint(x: c.x + dir.dx * half, y: c.y + dir.dy * half)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Approximates a mesh gradient: a flat base plus several soft radial blobs in the preset's colors.
    private static func drawMeshGradient(_ g: BackgroundStyle.Gradient, in rect: CGRect, context ctx: CGContext) {
        let stops = g.stops
        guard !stops.isEmpty else { return }
        let anchors: [CGPoint] = [
            CGPoint(x: 0.12, y: 0.18), CGPoint(x: 0.88, y: 0.22), CGPoint(x: 0.78, y: 0.86),
            CGPoint(x: 0.18, y: 0.80), CGPoint(x: 0.50, y: 0.45), CGPoint(x: 0.95, y: 0.60),
        ]
        ctx.saveGState()
        ctx.clip(to: rect)
        // Base: the average of the stops so the blobs blend into something cohesive.
        let avg = BackgroundStyle.RGBA(r: stops.map(\.r).reduce(0, +) / Double(stops.count),
                                       g: stops.map(\.g).reduce(0, +) / Double(stops.count),
                                       b: stops.map(\.b).reduce(0, +) / Double(stops.count))
        ctx.setFillColor(avg.cgColor)
        ctx.fill(rect)
        let radius = max(rect.width, rect.height) * 0.62
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        for (i, anchor) in anchors.enumerated() {
            let color = stops[i % stops.count]
            let colors = [color.nsColor.withAlphaComponent(0.95).cgColor, color.nsColor.withAlphaComponent(0).cgColor] as CFArray
            guard let radial = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { continue }
            let center = CGPoint(x: rect.minX + rect.width * anchor.x, y: rect.minY + rect.height * anchor.y)
            ctx.drawRadialGradient(radial, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        ctx.restoreGState()
    }

    // MARK: Single annotation

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

        case .curvedArrow(let from, let to, let control):
            drawCurvedArrow(from: from, to: to, control: control, lineWidth: lw, in: ctx)

        case .blackout(let r):
            ctx.fill(r)

        case .spotlight:
            // Normally batched by `drawComposite`; drawn alone when rendered in isolation.
            drawSpotlights([a], imageSize: imageSize, in: ctx)

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

    /// Quadratic curve from→to through `control`, with the head aligned to the curve's end tangent.
    private static func drawCurvedArrow(from: CGPoint, to: CGPoint, control: CGPoint, lineWidth lw: CGFloat, in ctx: CGContext) {
        let length = from.distance(to: to)
        guard length > 0.1 else { return }
        let headLength = min(length, max(lw * 3.2, 14))
        let headWidth = headLength * 0.85
        // Tangent at t = 1 of a quadratic Bézier is (to - control).
        var tx = to.x - control.x, ty = to.y - control.y
        let tlen = hypot(tx, ty)
        if tlen < 0.001 { tx = (to.x - from.x) / length; ty = (to.y - from.y) / length } else { tx /= tlen; ty /= tlen }
        let base = CGPoint(x: to.x - tx * headLength, y: to.y - ty * headLength)
        let nx = -ty, ny = tx

        // Shorten the curve so the round cap doesn't poke out of the head.
        let shaftEnd = CGPoint(x: to.x - tx * headLength * 0.7, y: to.y - ty * headLength * 0.7)
        ctx.move(to: from)
        ctx.addQuadCurve(to: shaftEnd, control: control)
        ctx.strokePath()

        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: base.x + nx * headWidth / 2, y: base.y + ny * headWidth / 2))
        ctx.addLine(to: CGPoint(x: base.x - nx * headWidth / 2, y: base.y - ny * headWidth / 2))
        ctx.closePath()
        ctx.fillPath()
    }

    /// Points along a quadratic curve, used for hit-testing curved arrows.
    static func curvePoints(from a: CGPoint, to b: CGPoint, control c: CGPoint, segments: Int = 24) -> [CGPoint] {
        (0...segments).map { i in
            let t = CGFloat(i) / CGFloat(segments), u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                           y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        }
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
        case .curvedArrow(let p, let q, let c):
            let pts = curvePoints(from: p, to: q, control: c)
            var r = CGRect(origin: pts[0], size: .zero)
            for pt in pts { r = r.union(CGRect(origin: pt, size: .zero)) }
            return r.insetBy(dx: -lw * 2, dy: -lw * 2)
        case .rect(let r), .ellipse(let r), .blur(let r), .blackout(let r), .spotlight(let r, _):
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
        case .curvedArrow(let a, let b, let c):
            let pts = curvePoints(from: a, to: b, control: c)
            return zip(pts, pts.dropFirst()).contains { p.distance(toSegment: $0, $1) <= tolerance }
        case .pen(let pts):
            return zip(pts, pts.dropFirst()).contains { p.distance(toSegment: $0, $1) <= tolerance }
        case .highlighter(let pts):
            return zip(pts, pts.dropFirst()).contains { p.distance(toSegment: $0, $1) <= tolerance * 2 }
        default:
            return bounds(of: a, pixelScale: s).insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p)
        }
    }
}
