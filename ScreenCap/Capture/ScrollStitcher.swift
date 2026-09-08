import CoreGraphics
import Accelerate

/// One captured frame plus the grayscale, horizontally downsampled buffers used for row matching.
/// `gray` keeps every row (offsets are found to the pixel); `coarse` is additionally shrunk
/// vertically by `coarseFactor` for the first, wide search.
struct ScrollFrame {
    let image: CGImage
    let width: Int
    let height: Int
    let grayWidth: Int
    let gray: [Float]
    let coarseFactor: Int
    let coarseHeight: Int
    let coarse: [Float]

    /// Target number of columns after horizontal downsampling.
    static let targetGrayWidth = 256

    init?(image: CGImage) {
        width = image.width
        height = image.height
        guard width > 0, height > 0 else { return nil }
        grayWidth = max(1, min(width, Self.targetGrayWidth))
        coarseFactor = height >= 128 ? 8 : 1
        coarseHeight = max(1, height / coarseFactor)
        guard let fine = ScrollStitcher.grayscale(image, width: grayWidth, height: height),
              let coarse = ScrollStitcher.grayscale(image, width: grayWidth, height: coarseHeight) else { return nil }
        self.image = image
        self.gray = fine
        self.coarse = coarse
    }
}

/// Rows at the top/bottom of the region that never move (sticky header, toolbar, footer).
struct ScrollBands: Equatable {
    var top = 0
    var bottom = 0
}

/// How the content moved between two consecutive frames.
enum ScrollMatch: Equatable {
    /// Content moved up by `rows` (normal downward scroll); `rows` new rows appeared at the bottom.
    case forward(rows: Int)
    /// Content moved down by `rows` (the scroll went the wrong way).
    case backward(rows: Int)
    /// Nothing changed.
    case still
    /// The frames overlap too little to be aligned.
    case lost
}

/// Pure image math for scrolling capture: grayscale conversion, static-band detection,
/// offset search between consecutive frames, and final composition of row slices.
enum ScrollStitcher {
    /// Rows whose mean difference is below this are considered unchanged.
    static let stillThreshold: Float = 0.006
    /// A candidate offset is accepted when its mean row difference is below this…
    static let matchThreshold: Float = 0.06
    /// …or when it is at least this much better than "no movement".
    static let relativeMatchFactor: Float = 0.5
    /// Static bands may not eat more than this share of the frame.
    static let maxBandFraction = 0.4

    // MARK: Grayscale

    /// Renders `image` into a `width`×`height` 8-bit gray bitmap and returns it as floats in 0…1, row-major.
    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [Float]? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        var floats = [Float](repeating: 0, count: width * height)
        vDSP_vfltu8(bytes, 1, &floats, 1, vDSP_Length(width * height))
        var scale: Float = 1 / 255
        vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(width * height))
        return floats
    }

    /// Mean absolute difference of two equally long float runs.
    static func meanAbsDiff(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var scratch = [Float](repeating: 0, count: count)
        vDSP_vsub(b, 1, a, 1, &scratch, 1, vDSP_Length(count))
        var mean: Float = 0
        vDSP_meamgv(scratch, 1, &mean, vDSP_Length(count))
        return mean
    }

    /// Mean absolute difference between rows `aRows` of `a` and the same number of rows starting at `bStart` in `b`.
    static func rowsDiff(_ a: [Float], _ aStart: Int, _ b: [Float], _ bStart: Int, rows: Int, width: Int) -> Float {
        guard rows > 0 else { return 0 }
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                meanAbsDiff(pa.baseAddress! + aStart * width, pb.baseAddress! + bStart * width, count: rows * width)
            }
        }
    }

    /// Whether two frames of the same size look identical (used to wait for scrolling to settle).
    static func areIdentical(_ a: ScrollFrame, _ b: ScrollFrame) -> Bool {
        guard a.width == b.width, a.height == b.height, a.gray.count == b.gray.count else { return false }
        return rowsDiff(a.gray, 0, b.gray, 0, rows: a.height, width: a.grayWidth) < stillThreshold
    }

    // MARK: Static bands

    /// Contiguous unchanged rows at the top and bottom of `current` versus `previous` (sticky header/footer).
    /// Blank content rows next to a band are counted as part of it; `ScrollStitchSession` recovers them
    /// as soon as they change.
    static func staticBands(previous: ScrollFrame, current: ScrollFrame) -> ScrollBands {
        let h = current.height, w = current.grayWidth
        guard previous.height == h, previous.grayWidth == w else { return ScrollBands() }
        let limit = Int(Double(h) * maxBandFraction)

        func isStatic(_ y: Int) -> Bool {
            rowsDiff(current.gray, y, previous.gray, y, rows: 1, width: w) < stillThreshold
        }

        var top = 0
        while top < limit, isStatic(top) { top += 1 }
        var bottom = 0
        while bottom < limit, isStatic(h - 1 - bottom) { bottom += 1 }
        return ScrollBands(top: top, bottom: bottom)
    }

    // MARK: Offset search

    /// Finds how far the content between the static bands moved from `previous` to `current`.
    /// `expected` (rows) breaks ties on featureless content; `allowBackward` also searches upward motion.
    static func findOffset(previous: ScrollFrame, current: ScrollFrame, bands: ScrollBands,
                           expected: Int, allowBackward: Bool) -> ScrollMatch {
        let h = current.height, w = current.grayWidth
        guard previous.height == h, previous.grayWidth == w, previous.coarseHeight == current.coarseHeight else { return .lost }

        let content = h - bands.top - bands.bottom
        let minOverlap = max(8, content / 10)
        guard content > minOverlap else { return .lost }

        let still = score(previous, current, bands: bands, offset: 0)
        if still < stillThreshold { return .still }

        let maxOffset = content - minOverlap
        let minOffset = allowBackward ? -maxOffset : 1
        let f = current.coarseFactor
        let coarseBands = ScrollBands(top: (bands.top + f - 1) / f, bottom: (bands.bottom + f - 1) / f)
        let penaltyScale = 0.005 / Float(max(h, 1))

        // Coarse pass: every offset at 1/f vertical resolution.
        var bestCoarse = 0
        var bestCoarseScore = Float.greatestFiniteMagnitude
        for dc in stride(from: minOffset / f, through: maxOffset / f, by: 1) where dc != 0 {
            let s = coarseScore(previous, current, bands: coarseBands, offset: dc)
            guard s.isFinite else { continue }
            let weighted = s + penaltyScale * Float(abs(dc * f - expected))
            if weighted < bestCoarseScore { bestCoarseScore = weighted; bestCoarse = dc }
        }
        guard bestCoarseScore.isFinite else { return .lost }

        // Fine pass: exact rows around the coarse winner.
        let centre = bestCoarse * f
        var best = 0
        var bestScore = Float.greatestFiniteMagnitude
        for d in max(minOffset, centre - f)...min(maxOffset, centre + f) where d != 0 {
            let s = score(previous, current, bands: bands, offset: d)
            let weighted = s + penaltyScale * Float(abs(d - expected))
            if weighted < bestScore { bestScore = weighted; best = d }
        }
        let plain = score(previous, current, bands: bands, offset: best)
        guard best != 0, plain <= matchThreshold || plain <= still * relativeMatchFactor else { return .lost }
        return best > 0 ? .forward(rows: best) : .backward(rows: -best)
    }

    /// Mean difference between the overlapping content rows when `current` is shifted by `offset` rows
    /// relative to `previous` (positive: content moved up). Full-row resolution.
    static func score(_ previous: ScrollFrame, _ current: ScrollFrame, bands: ScrollBands, offset: Int) -> Float {
        let h = current.height, w = current.grayWidth
        let rows = h - bands.top - bands.bottom - abs(offset)
        guard rows > 0 else { return .infinity }
        if offset >= 0 {
            return rowsDiff(current.gray, bands.top, previous.gray, bands.top + offset, rows: rows, width: w)
        } else {
            return rowsDiff(current.gray, bands.top - offset, previous.gray, bands.top, rows: rows, width: w)
        }
    }

    /// Same as `score` on the coarse buffers (offset in coarse rows).
    static func coarseScore(_ previous: ScrollFrame, _ current: ScrollFrame, bands: ScrollBands, offset: Int) -> Float {
        let h = current.coarseHeight, w = current.grayWidth
        let rows = h - bands.top - bands.bottom - abs(offset)
        guard rows > 0 else { return .infinity }
        if offset >= 0 {
            return rowsDiff(current.coarse, bands.top, previous.coarse, bands.top + offset, rows: rows, width: w)
        } else {
            return rowsDiff(current.coarse, bands.top - offset, previous.coarse, bands.top, rows: rows, width: w)
        }
    }

    // MARK: Slicing and composition

    /// Copies `rows` (top-left origin, pixels) of `image` into a standalone image so the source can be freed.
    static func slice(_ image: CGImage, rows: Range<Int>) -> CGImage? {
        guard !rows.isEmpty, rows.lowerBound >= 0, rows.upperBound <= image.height else { return nil }
        let rect = CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)
        guard let cropped = image.cropping(to: rect) else { return nil }
        return render(width: image.width, height: rows.count, colorSpace: image.colorSpace) { ctx in
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: image.width, height: rows.count))
        }
    }

    /// Stacks `slices` (all `width` wide) top to bottom into one image.
    static func compose(_ slices: [CGImage], width: Int) -> CGImage? {
        let total = slices.reduce(0) { $0 + $1.height }
        guard width > 0, total > 0 else { return nil }
        return render(width: width, height: total, colorSpace: slices.first?.colorSpace) { ctx in
            var y = 0
            for s in slices {
                ctx.draw(s, in: CGRect(x: 0, y: total - y - s.height, width: width, height: s.height))
                y += s.height
            }
        }
    }

    /// 8-bit BGRA bitmap context helper; `colorSpace` falls back to sRGB unless it is an RGB space.
    static func render(width: Int, height: Int, colorSpace: CGColorSpace?, draw: (CGContext) -> Void) -> CGImage? {
        let space = (colorSpace?.model == .rgb ? colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .none
        draw(ctx)
        return ctx.makeImage()
    }
}

/// Accumulates frames of one scrolling capture into row slices and composes the final tall image.
/// Runs off the main thread; the controller feeds it frames and reads back progress.
actor ScrollStitchSession {
    /// Stitched height (pixels) at which the capture stops.
    static let maxHeight = 20_000

    private(set) var width = 0
    private(set) var frameHeight = 0
    /// Rows stitched so far, not counting the footer band that is appended at the end.
    private(set) var contentHeight = 0
    private var slices: [CGImage] = []
    private var previous: ScrollFrame?
    private var bands: ScrollBands?
    private var stepCount = 0

    /// Total height the composed image will have right now.
    var totalHeight: Int { contentHeight + (bands?.bottom ?? 0) }
    var hasMoved: Bool { stepCount > 0 }

    /// Builds the matching buffers for a captured image.
    nonisolated func makeFrame(_ image: CGImage) -> ScrollFrame? { ScrollFrame(image: image) }

    /// Starts (or restarts) with `first` as the top of the stitched image.
    func begin(with first: ScrollFrame) {
        width = first.width
        frameHeight = first.height
        slices = [first.image]
        contentHeight = first.height
        previous = first
        bands = nil
        stepCount = 0
    }

    /// Whether frames of this size can be compared with the ones already stitched.
    func accepts(_ frame: ScrollFrame) -> Bool { frame.width == width && frame.height == frameHeight }

    /// Aligns `frame` with the previous one and appends the newly revealed rows.
    /// `expected` is the requested scroll distance in pixels; backward motion is only reported on the first step.
    func append(_ frame: ScrollFrame, expected: Int) -> ScrollMatch {
        guard let prev = previous, accepts(frame) else { return .lost }
        var current = bands ?? ScrollBands()
        let detected = ScrollStitcher.staticBands(previous: prev, current: frame)
        let match = ScrollStitcher.findOffset(previous: prev, current: frame, bands: bands ?? detected,
                                              expected: expected, allowBackward: stepCount == 0)
        guard case .forward(let rows) = match else { return match }

        if bands == nil {
            // First real movement: the static rows become the header/footer. The first frame already holds
            // the header; drop its footer rows so they can be re-appended from the last frame.
            current = detected
            if current.bottom > 0, let first = slices.first, let trimmed = ScrollStitcher.slice(first, rows: 0..<(frameHeight - current.bottom)) {
                slices[0] = trimmed
                contentHeight -= current.bottom
            }
        } else {
            // A band that turned out to move was content after all: shrink it and recover the rows we skipped.
            current.top = min(current.top, detected.top)
            let newBottom = min(current.bottom, detected.bottom)
            if newBottom < current.bottom, let recovered = ScrollStitcher.slice(prev.image, rows: (frameHeight - current.bottom)..<(frameHeight - newBottom)) {
                slices.append(recovered)
                contentHeight += recovered.height
            }
            current.bottom = newBottom
        }
        bands = current

        let end = frameHeight - current.bottom
        let start = max(current.top, end - rows)
        guard start < end, let piece = ScrollStitcher.slice(frame.image, rows: start..<end) else { return .lost }
        slices.append(piece)
        contentHeight += piece.height
        previous = frame
        stepCount += 1
        return .forward(rows: piece.height)
    }

    /// Composes everything captured so far, appending the footer band from the last frame.
    func compose() -> CGImage? {
        var all = slices
        if let bands, bands.bottom > 0, let last = previous,
           let footer = ScrollStitcher.slice(last.image, rows: (frameHeight - bands.bottom)..<frameHeight) {
            all.append(footer)
        }
        if all.count == 1 { return all[0] }
        return ScrollStitcher.compose(all, width: width)
    }
}
