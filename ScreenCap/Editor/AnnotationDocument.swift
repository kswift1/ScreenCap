import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

@MainActor
final class AnnotationDocument: ObservableObject {
    /// One undo step: the annotation list plus the background style at that moment.
    struct Snapshot {
        var annotations: [Annotation]
        var background: BackgroundStyle
    }

    let baseImage: CGImage
    let pixelScale: CGFloat
    var pixelSize: CGSize { CGSize(width: baseImage.width, height: baseImage.height) }

    @Published var annotations: [Annotation] = []
    @Published var selectedID: UUID?
    @Published var tool: AnnotationTool = .arrow
    @Published var style = AnnotationStyle(color: .systemRed, lineWidth: 4, fontSize: 24)
    /// Background/padding applied around the screenshot; restored from the last session.
    @Published var backgroundStyle: BackgroundStyle = .load()
    @Published private(set) var undoStack: [Snapshot] = []
    @Published private(set) var redoStack: [Snapshot] = []
    @Published var isDirty = false

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selected: Annotation? { annotations.first { $0.id == selectedID } }

    /// Pixel geometry of the composite for the current background style.
    var compositeLayout: CompositeLayout {
        CompositeLayout(imageSize: pixelSize, style: backgroundStyle, pixelScale: pixelScale)
    }

    lazy var pixelatedImage: CGImage? = makePixelated()

    init(image: CGImage, pixelScale: CGFloat) {
        self.baseImage = image
        self.pixelScale = pixelScale
    }

    var nextNumber: Int {
        (annotations.compactMap { if case .number(let n, _) = $0.shape { return n } else { return nil } }.max() ?? 0) + 1
    }

    // MARK: Mutation with undo

    private var snapshot: Snapshot { Snapshot(annotations: annotations, background: backgroundStyle) }

    func pushUndo() {
        undoStack.append(snapshot)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        isDirty = true
    }

    func add(_ a: Annotation) {
        pushUndo()
        annotations.append(a)
    }

    func replace(_ a: Annotation) {
        guard let i = annotations.firstIndex(where: { $0.id == a.id }) else { return }
        annotations[i] = a
    }

    func removeSelected() {
        guard let id = selectedID else { return }
        pushUndo()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    private func restore(_ s: Snapshot) {
        annotations = s.annotations
        if s.background != backgroundStyle {
            backgroundStyle = s.background
            backgroundStyle.save()
        }
        selectedID = nil
    }

    /// Applies the current color/width to the selected annotation (used when the palette changes).
    func applyStyleToSelection() {
        guard var a = selected else { return }
        pushUndo()
        a.style = style
        replace(a)
    }

    // MARK: Background edits

    private var backgroundGestureActive = false
    private var lastBackgroundEditKey: String?
    private var lastBackgroundEditTime: Date = .distantPast

    /// Starts a continuous edit (slider drag): one undo step is recorded now, none until `endBackgroundGesture`.
    func beginBackgroundGesture() {
        guard !backgroundGestureActive else { return }
        pushUndo()
        backgroundGestureActive = true
        lastBackgroundEditKey = nil
    }

    func endBackgroundGesture() {
        guard backgroundGestureActive else { return }
        backgroundGestureActive = false
        backgroundStyle.save()
    }

    /// Applies a background change. Outside a gesture each call is its own undo step, except that
    /// rapid successive edits sharing `coalescing` (e.g. the color picker) collapse into one.
    func updateBackground(coalescing key: String? = nil, _ mutate: (inout BackgroundStyle) -> Void) {
        var next = backgroundStyle
        mutate(&next)
        next = next.clamped()
        guard next != backgroundStyle else { return }
        if !backgroundGestureActive {
            let now = Date()
            let coalesce = key != nil && key == lastBackgroundEditKey && now.timeIntervalSince(lastBackgroundEditTime) < 1.0
            if !coalesce { pushUndo() }
            lastBackgroundEditKey = key
            lastBackgroundEditTime = now
        }
        backgroundStyle = next
        if !backgroundGestureActive { next.save() }
    }

    // MARK: Rendering

    /// The exported composite (background, padded screenshot, annotations) at full pixel size.
    func render() -> CGImage? {
        let layout = compositeLayout
        let w = Int(layout.canvasSize.width.rounded()), h = Int(layout.canvasSize.height.rounded())
        guard w > 0, h > 0 else { return nil }
        let source = baseImage.colorSpace
        let space = (source?.model == .rgb ? source : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        // Flip so the shared renderer can work in y-down image coordinates.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        AnnotationRenderer.drawComposite(image: baseImage, annotations: annotations, pixelated: pixelatedImage,
                                         background: backgroundStyle, layout: layout, pixelScale: pixelScale,
                                         shadowScale: 1, in: ctx)
        return ctx.makeImage()
    }

    private func makePixelated() -> CGImage? {
        let input = CIImage(cgImage: baseImage)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(14 * pixelScale)
        filter.center = CGPoint(x: input.extent.midX, y: input.extent.midY)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        let context = CIContext()
        return context.createCGImage(output, from: input.extent)
    }
}
