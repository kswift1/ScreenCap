import AppKit

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, ellipse, pen, highlighter, text, blur, number

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .blur: return "eye.slash"
        case .number: return "1.circle"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .blur: return "Pixelate"
        case .number: return "Counter"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .ellipse: return "o"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .blur: return "b"
        case .number: return "n"
        }
    }
}

struct AnnotationStyle: Equatable {
    var color: NSColor
    /// In points; multiplied by the image's pixel scale when drawn.
    var lineWidth: CGFloat
    var fontSize: CGFloat
}

/// All geometry is in image pixel coordinates with a top-left origin.
struct Annotation: Identifiable, Equatable {
    enum Shape: Equatable {
        case arrow(from: CGPoint, to: CGPoint)
        case line(from: CGPoint, to: CGPoint)
        case rect(CGRect)
        case ellipse(CGRect)
        case pen([CGPoint])
        case highlighter([CGPoint])
        case text(String, origin: CGPoint)
        case blur(CGRect)
        case number(Int, center: CGPoint)
    }

    let id: UUID
    var shape: Shape
    var style: AnnotationStyle

    init(id: UUID = UUID(), shape: Shape, style: AnnotationStyle) {
        self.id = id
        self.shape = shape
        self.style = style
    }

    func translated(by d: CGPoint) -> Annotation {
        var copy = self
        func mv(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.x, y: p.y + d.y) }
        switch shape {
        case .arrow(let a, let b): copy.shape = .arrow(from: mv(a), to: mv(b))
        case .line(let a, let b): copy.shape = .line(from: mv(a), to: mv(b))
        case .rect(let r): copy.shape = .rect(r.offsetBy(dx: d.x, dy: d.y))
        case .ellipse(let r): copy.shape = .ellipse(r.offsetBy(dx: d.x, dy: d.y))
        case .pen(let pts): copy.shape = .pen(pts.map(mv))
        case .highlighter(let pts): copy.shape = .highlighter(pts.map(mv))
        case .text(let s, let o): copy.shape = .text(s, origin: mv(o))
        case .blur(let r): copy.shape = .blur(r.offsetBy(dx: d.x, dy: d.y))
        case .number(let n, let c): copy.shape = .number(n, center: mv(c))
        }
        return copy
    }

    /// Whether the shape is big enough to be worth keeping after a drag.
    var isMeaningful: Bool {
        switch shape {
        case .arrow(let a, let b), .line(let a, let b): return a.distance(to: b) > 3
        case .rect(let r), .ellipse(let r), .blur(let r): return r.width > 3 && r.height > 3
        case .pen(let p), .highlighter(let p): return p.count > 1
        case .text(let s, _): return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number: return true
        }
    }
}
