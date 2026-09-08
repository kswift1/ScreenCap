import AppKit
import SwiftUI
import Combine

/// "Capture History": a regular window (this one does activate the app) showing every recent capture
/// as a thumbnail grid with the usual Copy / Save / Annotate / Pin actions, search, and delete.
@MainActor
final class HistoryWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    static let shared = HistoryWindowController()

    let model = HistoryViewModel()
    private var searchItem: NSSearchToolbarItem?

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Capture History"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 480, height: 320)
        window.center()
        window.setFrameAutosaveName("CaptureHistory")
        window.toolbarStyle = .unified
        super.init(window: window)
        window.contentView = NSHostingView(rootView: HistoryView(model: model, controller: self))

        let toolbar = NSToolbar(identifier: "CaptureHistoryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        HistoryStore.shared.pruneMissing()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Toolbar

    private enum ItemID {
        static let search = NSToolbarItem.Identifier("history.search")
        static let clear = NSToolbarItem.Identifier("history.clear")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ItemID.search, ItemID.clear]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ItemID.search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.preferredWidthForSearchField = 220
            item.searchField.placeholderString = "Search type or date (video, 09-08, 22:41)"
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            searchItem = item
            return item
        case ItemID.clear:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Clear History"
            item.paletteLabel = "Clear History"
            item.toolTip = "Remove every entry (saved files are kept)"
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear History")
            item.isBordered = true
            item.target = self
            item.action = #selector(clearHistoryTapped(_:))
            return item
        default:
            return nil
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        model.query = sender.stringValue
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSearchField { model.query = field.stringValue }
    }

    @objc private func clearHistoryTapped(_ sender: Any?) {
        clearHistory()
    }

    // MARK: Actions

    /// Removes every entry after confirmation. Temp files go; files in the save folder stay.
    func clearHistory() {
        guard let window, !HistoryStore.shared.items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Clear capture history?"
        alert.informativeText = "All \(HistoryStore.shared.items.count) entries are removed and their temporary files deleted. Captures you saved stay on disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            HistoryStore.shared.clear()
            QuickAccessController.shared.removeAll()
        }
    }

    /// Deletes one capture's file(s) and its entry after confirmation.
    func delete(_ item: CaptureItem) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(item.url.lastPathComponent)\"?"
        var files = [item.url.path]
        if let saved = item.savedURL, saved != item.url { files.append(saved.path) }
        alert.informativeText = "The file is removed from disk and from the history:\n" + files.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            QuickAccessController.shared.remove(item, animated: false)
            HistoryStore.shared.remove(item, deleteFiles: true)
        }
    }

    func copy(_ item: CaptureItem) {
        if let image = item.image {
            Clipboard.copy(image: image, pixelScale: item.pixelScale)
        } else {
            Clipboard.copy(fileURL: item.fileURL)
        }
    }

    func save(_ item: CaptureItem) {
        do { try FileStore.saveToUserFolder(item) } catch { ErrorPresenter.show(error, title: "Couldn't save") }
    }

    func saveAs(_ item: CaptureItem) { QuickAccessController.shared.saveAs(item) }

    func annotate(_ item: CaptureItem) {
        guard let image = item.image else { return }
        EditorWindowController.open(image: image, pixelScale: item.pixelScale, sourceItem: item)
    }

    func pin(_ item: CaptureItem) {
        guard item.isImage else { return }
        PinController.shared.pin(item, at: item.sourceRect)
    }

    func open(_ item: CaptureItem) { NSWorkspace.shared.open(item.savedURL ?? item.fileURL) }

    func revealInFinder(_ item: CaptureItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.savedURL ?? item.fileURL])
    }
}

/// Search state plus the filtered, newest-first list the grid shows.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var filtered: [CaptureItem] = []

    private var cancellables: Set<AnyCancellable> = []

    init() {
        HistoryStore.shared.$items
            .combineLatest($query.removeDuplicates())
            .map { items, query in HistoryViewModel.filter(items, query: query) }
            .sink { [weak self] in self?.filtered = $0 }
            .store(in: &cancellables)
    }

    /// Every whitespace-separated token must appear in the item's search text (type, dates, times, file name, size).
    static func filter(_ items: [CaptureItem], query: String) -> [CaptureItem] {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let newestFirst = Array(items.reversed())
        guard !tokens.isEmpty else { return newestFirst }
        return newestFirst.filter { item in
            let haystack = HistorySearch.text(for: item)
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }
}

/// Builds the lowercase text a history item is matched against.
enum HistorySearch {
    private static let numericDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss yyyy/MM/dd HH.mm"
        return f
    }()

    @MainActor
    static func text(for item: CaptureItem) -> String {
        var parts = [item.kind.rawValue, item.kind.title, item.url.lastPathComponent]
        if item.kind == .image { parts.append("photo screenshot") }
        if item.kind == .video { parts.append("movie recording mp4") }
        parts.append(numericDate.string(from: item.createdAt))
        parts.append(item.createdAt.formatted(date: .abbreviated, time: .shortened))
        parts.append(item.createdAt.formatted(date: .complete, time: .omitted))
        if Calendar.current.isDateInToday(item.createdAt) { parts.append("today") }
        if Calendar.current.isDateInYesterday(item.createdAt) { parts.append("yesterday") }
        if let size = item.pixelSize { parts.append("\(Int(size.width))x\(Int(size.height)) \(Int(size.width))×\(Int(size.height))") }
        if item.savedURL != nil { parts.append("saved") }
        return parts.joined(separator: " ").lowercased()
    }
}
