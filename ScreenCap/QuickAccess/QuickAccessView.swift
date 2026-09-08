import SwiftUI

struct QuickAccessView: View {
    @ObservedObject var controller: QuickAccessController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(controller.items) { item in
                QuickAccessCard(item: item, controller: controller)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .padding(16)
        .fixedSize()
        .background(GeometryReader { geo in
            Color.clear.preference(key: SizeKey.self, value: geo.size)
        })
        .onPreferenceChange(SizeKey.self) { size in
            controller.updatePanelSize(size)
        }
    }

    private struct SizeKey: PreferenceKey {
        static var defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
    }
}

struct QuickAccessCard: View {
    @ObservedObject var item: CaptureItem
    let controller: QuickAccessController
    @State private var hovering = false

    private let width: CGFloat = 224

    private var thumbSize: CGSize {
        guard let t = item.thumbnail, t.size.width > 0 else { return CGSize(width: width, height: width * 0.6) }
        let ratio = t.size.height / t.size.width
        let h = min(max(width * ratio, 60), 170)
        return CGSize(width: width, height: h)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            thumbnail
                .frame(width: thumbSize.width, height: thumbSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)

            if hovering && !item.isBusy {
                Button { controller.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.7))
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
            }

            VStack {
                Spacer()
                if hovering && !item.isBusy { actionBar }
            }
            .frame(width: thumbSize.width, height: thumbSize.height)

            if item.isBusy {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.45))
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .overlay(ProgressView().controlSize(.small).tint(.white))
            }
        }
        .frame(width: thumbSize.width, height: thumbSize.height)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            controller.setHovering(item, h)
        }
        .onTapGesture(count: 2) {
            if item.isImage { controller.annotate(item) } else { controller.openExternally(item) }
        }
        .onDrag { NSItemProvider(contentsOf: item.savedURL ?? item.url) ?? NSItemProvider() }
        .contextMenu { menu }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            if let t = item.thumbnail {
                Image(nsImage: t)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.isVideo ? "film" : "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
            if item.isVideo || item.kind.isGIF {
                VStack {
                    HStack {
                        Spacer()
                        badge(item.kind.isGIF ? "GIF" : durationText)
                    }
                    Spacer()
                }
                .padding(8)
            }
            if item.savedURL != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(.green.opacity(0.9)))
                            .foregroundStyle(.white)
                    }
                }
                .padding(8)
            }
        }
    }

    private var durationText: String {
        let s = Int(item.duration ?? 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.7)))
            .foregroundStyle(.white)
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            actionButton("doc.on.doc", "Copy") { controller.copy(item) }
            actionButton("square.and.arrow.down", "Save to \(Preferences.saveDirectory.lastPathComponent)") { controller.save(item) }
            if item.isImage {
                actionButton("pencil.tip.crop.circle", "Annotate") { controller.annotate(item) }
            }
            if item.isVideo {
                actionButton("photo.stack", "Convert to GIF") { controller.convertToGIF(item) }
                actionButton("play.rectangle", "Open") { controller.openExternally(item) }
            }
            if item.kind.isGIF {
                actionButton("arrow.up.forward.app", "Open") { controller.openExternally(item) }
            }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(.white.opacity(0.15)))
        .padding(.bottom, 8)
        .transition(.opacity)
    }

    private func actionButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Copy") { controller.copy(item) }
        Button("Save") { controller.save(item) }
        Button("Save As…") { controller.saveAs(item) }
        Divider()
        if item.isImage { Button("Annotate") { controller.annotate(item) } }
        if item.isVideo { Button("Convert to GIF") { controller.convertToGIF(item) } }
        Button("Open") { controller.openExternally(item) }
        Button("Show in Finder") { controller.revealInFinder(item) }
        Divider()
        Button("Dismiss") { controller.remove(item) }
    }
}

extension CaptureItem.Kind {
    var isGIF: Bool { if case .gif = self { return true } else { return false } }
}
