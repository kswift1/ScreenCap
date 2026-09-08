import SwiftUI

/// Thumbnail grid for the Capture History window, newest first.
struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    let controller: HistoryWindowController

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)]

    var body: some View {
        Group {
            if model.filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.filtered) { item in
                            HistoryCell(item: item, controller: controller)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.query.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "No captures yet" : "No captures match \"\(model.query)\"")
                .font(.title3)
                .foregroundStyle(.secondary)
            if model.query.isEmpty {
                Text("Screenshots, recordings and GIFs you take will show up here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One capture: thumbnail with type badge, hover actions, and a caption with time and pixel size.
struct HistoryCell: View {
    @ObservedObject var item: CaptureItem
    let controller: HistoryWindowController
    @State private var hovering = false

    private let thumbHeight: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
                .frame(height: thumbHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.primary.opacity(hovering ? 0.25 : 0.1), lineWidth: 1))
                .overlay(alignment: .topLeading) { kindBadge.padding(6) }
                .overlay(alignment: .topTrailing) { if item.savedURL != nil { savedBadge.padding(6) } }
                .overlay(alignment: .bottom) { if hovering { actionBar.padding(.bottom, 6) } }
            caption
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { controller.open(item) }
        .onDrag { NSItemProvider(contentsOf: item.savedURL ?? item.fileURL) ?? NSItemProvider() }
        .contextMenu { menu }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            if let t = item.thumbnail {
                Image(nsImage: t)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else {
                Image(systemName: item.isVideo ? "film" : "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var kindBadge: some View {
        Label {
            Text(badgeText)
        } icon: {
            Image(systemName: badgeSymbol)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.7)))
        .foregroundStyle(.white)
    }

    private var savedBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 13))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .green)
            .help("Saved to \(item.savedURL?.deletingLastPathComponent().lastPathComponent ?? "")")
    }

    private var badgeText: String {
        switch item.kind {
        case .image: return "Image"
        case .gif: return "GIF"
        case .video:
            guard let d = item.duration else { return "Video" }
            let s = Int(d.rounded())
            return String(format: "Video %d:%02d", s / 60, s % 60)
        }
    }

    private var badgeSymbol: String {
        switch item.kind {
        case .image: return "photo"
        case .gif: return "photo.stack"
        case .video: return "film"
        }
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(timeText)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(sizeText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
    }

    private var timeText: String {
        let date = item.createdAt
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var sizeText: String {
        guard let s = item.pixelSize else { return "" }
        return "\(Int(s.width)) × \(Int(s.height))"
    }

    /// Hover buttons, mirroring Quick Access: Copy, Save, and for images Annotate and Pin.
    private var actionBar: some View {
        HStack(spacing: 2) {
            actionButton("doc.on.doc", "Copy") { controller.copy(item) }
            actionButton("square.and.arrow.down", "Save to \(Preferences.saveDirectory.lastPathComponent)") { controller.save(item) }
            if item.isImage {
                actionButton("pencil.tip.crop.circle", "Annotate") { controller.annotate(item) }
                actionButton("pin", "Pin on screen") { controller.pin(item) }
            } else {
                actionButton("play.rectangle", "Open") { controller.open(item) }
            }
        }
        .padding(3)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(.white.opacity(0.15)))
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
        if item.isImage {
            Button("Annotate") { controller.annotate(item) }
            Button("Pin on Screen") { controller.pin(item) }
            Divider()
        }
        Button("Open") { controller.open(item) }
        Button("Show in Finder") { controller.revealInFinder(item) }
        Divider()
        Button("Delete…", role: .destructive) { controller.delete(item) }
    }
}
