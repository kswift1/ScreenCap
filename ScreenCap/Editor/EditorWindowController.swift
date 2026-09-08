import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [EditorWindowController] = []

    let annotationDocument: AnnotationDocument
    private let sourceItem: CaptureItem?

    static func open(image: CGImage, pixelScale: CGFloat, sourceItem: CaptureItem?) {
        let controller = EditorWindowController(image: image, pixelScale: pixelScale, sourceItem: sourceItem)
        openControllers.append(controller)
        controller.show()
    }

    private init(image: CGImage, pixelScale: CGFloat, sourceItem: CaptureItem?) {
        self.annotationDocument = AnnotationDocument(image: image, pixelScale: pixelScale)
        self.sourceItem = sourceItem

        let screen = NSScreen.underMouse.visibleFrame
        // Size the window for the composite (image + remembered padding) so it opens at 1:1 when it fits.
        let pad = annotationDocument.backgroundStyle.padding * 2
        let logical = CGSize(width: CGFloat(image.width) / pixelScale + pad, height: CGFloat(image.height) / pixelScale + pad)
        let toolbarHeight: CGFloat = 52
        let width = min(max(logical.width + 48, 720), screen.width * 0.9)
        let height = min(max(logical.height + 48 + toolbarHeight, 480), screen.height * 0.9)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = sourceItem?.url.lastPathComponent ?? "Annotate"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 600, height: 400)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: EditorView(document: annotationDocument, controller: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Actions

    func copyToClipboard() {
        guard let image = annotationDocument.render() else { return }
        Clipboard.copy(image: image, pixelScale: annotationDocument.pixelScale)
        annotationDocument.isDirty = false
        flashTitle("Copied")
    }

    func save() {
        guard let image = annotationDocument.render() else { return }
        do {
            let url = try FileStore.saveToUserFolder(image: image, pixelScale: annotationDocument.pixelScale, date: sourceItem?.createdAt ?? .now)
            sourceItem?.savedURL = url
            annotationDocument.isDirty = false
            if Preferences.copyToClipboard { Clipboard.copy(image: image, pixelScale: annotationDocument.pixelScale) }
            SoundPlayer.playCapture()
            window?.close()
        } catch {
            ErrorPresenter.show(error, title: "Couldn't save")
        }
    }

    func saveAs() {
        guard let image = annotationDocument.render(), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = FileStore.fileName(ext: Preferences.fileFormat.fileExtension, date: sourceItem?.createdAt ?? .now)
        panel.directoryURL = Preferences.saveDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let format: ImageFormat = url.pathExtension.lowercased().hasPrefix("jp") ? .jpg : .png
            do {
                try FileStore.write(image, to: url, format: format, pixelScale: self.annotationDocument.pixelScale)
                self.annotationDocument.isDirty = false
            } catch {
                ErrorPresenter.show(error, title: "Couldn't save")
            }
        }
    }

    private func flashTitle(_ text: String) {
        guard let window else { return }
        let original = window.title
        window.title = "\(text) ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { window.title = original }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard annotationDocument.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard your annotations?"
        alert.informativeText = "You haven't saved or copied this image since your last change."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(); return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.openControllers.removeAll { $0 === self }
    }
}

struct EditorView: View {
    @ObservedObject var document: AnnotationDocument
    unowned let controller: EditorWindowController
    @State private var showBackground = false

    private let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .frame(height: 52)
                .background(.bar)
            Divider()
            AnnotationCanvas(document: document)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationTool.allCases) { tool in
                Button { document.tool = tool } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(document.tool == tool ? Color.accentColor.opacity(0.22) : .clear))
                        .foregroundStyle(document.tool == tool ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (\(tool.shortcut.uppercased()))")
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            HStack(spacing: 5) {
                ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                    Button { setColor(color) } label: {
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.primary.opacity(0.25), lineWidth: 0.5))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: document.style.color == color ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: document.style.color) },
                    set: { setColor(NSColor($0)) }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 24)
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            Picker("", selection: Binding(get: { document.style.lineWidth }, set: { setLineWidth($0) })) {
                ForEach([2.0, 4.0, 6.0, 8.0, 12.0], id: \.self) { w in
                    Label { Text("\(Int(w)) pt") } icon: {
                        Capsule().fill(.primary).frame(width: 18, height: w * 0.8 + 1)
                    }.tag(CGFloat(w))
                }
            }
            .labelsHidden()
            .frame(width: 84)
            .help("Line width")

            Picker("", selection: Binding(get: { document.style.fontSize }, set: { setFontSize($0) })) {
                ForEach([16.0, 20.0, 24.0, 32.0, 48.0], id: \.self) { s in
                    Text("\(Int(s)) pt").tag(CGFloat(s))
                }
            }
            .labelsHidden()
            .frame(width: 76)
            .help("Text size")

            Divider().frame(height: 22).padding(.horizontal, 4)

            Button { showBackground.toggle() } label: {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(backgroundActive ? Color.accentColor.opacity(0.22) : .clear))
                    .foregroundStyle(backgroundActive ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help("Background & padding")
            .popover(isPresented: $showBackground, arrowEdge: .bottom) {
                BackgroundInspector(document: document)
            }

            Spacer()

            Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!document.canUndo)
                .help("Undo (⌘Z)")
            Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!document.canRedo)
                .help("Redo (⇧⌘Z)")

            Divider().frame(height: 22).padding(.horizontal, 4)

            Button("Copy") { controller.copyToClipboard() }
                .help("Copy the annotated image (⌘C)")
            Button("Save As…") { controller.saveAs() }
            Button("Save") { controller.save() }
                .buttonStyle(.borderedProminent)
                .help("Save to \(Preferences.saveDirectory.lastPathComponent) and close")
        }
    }

    /// Highlights the Background button while the popover is open or a background/padding is in effect.
    private var backgroundActive: Bool {
        showBackground || document.backgroundStyle.kind != .none || document.backgroundStyle.padding > 0
    }

    private func setColor(_ c: NSColor) {
        document.style.color = c
        document.applyStyleToSelection()
    }

    private func setLineWidth(_ w: CGFloat) {
        document.style.lineWidth = w
        document.applyStyleToSelection()
    }

    private func setFontSize(_ s: CGFloat) {
        document.style.fontSize = s
        document.applyStyleToSelection()
    }
}
