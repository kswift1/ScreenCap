import AppKit
import SwiftUI

/// Popover content for the toolbar's Background button: kind, gradient presets, solid color,
/// padding, corner radius and shadow. Every change applies live; sliders coalesce into one undo step.
struct BackgroundInspector: View {
    @ObservedObject var document: AnnotationDocument

    private var style: BackgroundStyle { document.backgroundStyle }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Background", selection: Binding(
                get: { style.kind },
                set: { kind in document.updateBackground { $0.kind = kind } }
            )) {
                ForEach(BackgroundStyle.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch style.kind {
            case .gradient, .mesh:
                presetGrid
            case .solid:
                HStack {
                    Text("Color")
                    Spacer()
                    ColorPicker("Background color", selection: Binding(
                        get: { Color(nsColor: style.solidColor.nsColor) },
                        set: { c in document.updateBackground(coalescing: "solidColor") { $0.solidColor = .init(NSColor(c)) } }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
            case .none:
                Text("Padding stays transparent without a background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            slider("Padding", value: style.padding, range: BackgroundStyle.paddingRange, step: 1, unit: "pt") { $0.padding = $1 }
            slider("Corners", value: style.cornerRadius, range: BackgroundStyle.cornerRadiusRange, step: 1, unit: "pt") { $0.cornerRadius = $1 }

            Divider()

            Toggle("Shadow", isOn: Binding(
                get: { style.shadowEnabled },
                set: { on in document.updateBackground { $0.shadowEnabled = on } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            slider("Blur", value: style.shadowBlur, range: BackgroundStyle.shadowBlurRange, step: 1, unit: "pt") { $0.shadowBlur = $1 }
                .disabled(!style.shadowEnabled)
            slider("Opacity", value: style.shadowOpacity * 100, range: 0...100, step: 1, unit: "%") { $0.shadowOpacity = $1 / 100 }
                .disabled(!style.shadowEnabled)
        }
        .padding(16)
        .frame(width: 300)
    }

    /// Gradient preset swatches (shared by the Gradient and Mesh kinds).
    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(BackgroundStyle.presets) { preset in
                Button {
                    document.updateBackground { $0.gradientID = preset.id }
                } label: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(
                            colors: preset.stops.map { Color(nsColor: $0.nsColor) },
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.primary.opacity(0.15), lineWidth: 0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.accentColor, lineWidth: style.gradientID == preset.id ? 2 : 0)
                                .padding(-2)
                        )
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }

    /// A labelled slider whose drag becomes a single undo step.
    private func slider(_ title: String, value: CGFloat, range: ClosedRange<CGFloat>, step: CGFloat, unit: String,
                        apply: @escaping (inout BackgroundStyle, CGFloat) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 56, alignment: .leading)
            Slider(value: Binding(
                get: { value },
                set: { v in document.updateBackground(coalescing: title) { apply(&$0, v) } }
            ), in: range, step: step) { editing in
                if editing { document.beginBackgroundGesture() } else { document.endBackgroundGesture() }
            }
            Text("\(Int(value.rounded()))\(unit)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
