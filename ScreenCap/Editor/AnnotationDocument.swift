import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

@MainActor
final class AnnotationDocument: ObservableObject {
    let baseImage: CGImage
    let pixelScale: CGFloat
    var pixelSize: CGSize { CGSize(width: baseImage.width, height: baseImage.height) }

    @Published var annotations: [Annotation] = []
    @Published var selectedID: UUID?
    @Published var tool: AnnotationTool = .arrow
    @Published var style = AnnotationStyle(color: .systemRed, lineWidth: 4, fontSize: 24)
    @Published private(set) var undoStack: [[Annotation]] = []
    @Published private(set) var redoStack: [[Annotation]] = []
    @Published var isDirty = false

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selected: Annotation? { annotations.first { $0.id == selectedID } }

    lazy var pixelatedImage: CGImage? = makePixelated()

    init(image: CGImage, pixelScale: CGFloat) {
        self.baseImage = image
        self.pixelScale = pixelScale
    }

    var nextNumber: Int {
        (annotations.compactMap { if case .number(let n, _) = $0.shape { return n } else { return nil } }.max() ?? 0) + 1
    }

    // MARK: Mutation with undo

    func pushUndo() {
        undoStack.append(annotations)
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
        redoStack.append(annotations)
        annotations = prev
        selectedID = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selectedID = nil
    }

    /// Applies the current color/width to the selected annotation (used when the palette changes).
    func applyStyleToSelection() {
        guard var a = selected else { return }
        pushUndo()
        a.style = style
        replace(a)
    }

    // MARK: Rendering

    func render() -> CGImage? {
        let w = baseImage.width, h = baseImage.height
        let space = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        // Flip so the shared renderer can work in y-down image coordinates.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        AnnotationRenderer.drawImage(baseImage, in: CGRect(origin: .zero, size: pixelSize), context: ctx)
        for a in annotations {
            AnnotationRenderer.draw(a, in: ctx, pixelScale: pixelScale, pixelated: pixelatedImage, imageSize: pixelSize)
        }
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
