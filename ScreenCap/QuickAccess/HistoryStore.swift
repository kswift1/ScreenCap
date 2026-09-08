import AppKit
import Combine

/// Persists capture metadata to ~/Library/Application Support/ScreenCap/history.json so recent
/// captures survive relaunches. Files stay where they are (temp or save folder); entries whose
/// file has vanished are pruned on load. Newest entries are last.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let capacity = 200
    /// Only this many most-recent items keep their full image in memory; older ones reload from disk.
    static let inMemoryImageCount = 12

    /// One line of history.json.
    struct Record: Codable {
        let id: UUID
        let kind: CaptureItem.Kind
        let url: URL
        let savedURL: URL?
        let createdAt: Date
        let pixelScale: CGFloat
        let pixelWidth: Int?
        let pixelHeight: Int?
        let sourceRect: CGRect?
        let duration: TimeInterval?

        @MainActor init(_ item: CaptureItem) {
            id = item.id
            kind = item.kind
            url = item.url
            savedURL = item.savedURL
            createdAt = item.createdAt
            pixelScale = item.pixelScale
            pixelWidth = item.pixelSize.map { Int($0.width) }
            pixelHeight = item.pixelSize.map { Int($0.height) }
            sourceRect = item.sourceRect
            duration = item.duration
        }
    }

    @Published private(set) var items: [CaptureItem] = []

    private let fileURL: URL
    private var observers: [UUID: AnyCancellable] = [:]
    private var saveScheduled = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("ScreenCap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    // MARK: Mutations

    /// Appends a fresh capture (or moves an existing one to the end) and persists.
    func add(_ item: CaptureItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: i)
        }
        items.append(item)
        observe(item)
        if items.count > Self.capacity {
            let dropped = items.prefix(items.count - Self.capacity)
            dropped.forEach { forget($0) }
            items.removeFirst(items.count - Self.capacity)
        }
        evictOldImage()
        save()
    }

    /// Removes the entry; `deleteFiles` also trashes the temp file and the saved copy.
    func remove(_ item: CaptureItem, deleteFiles: Bool) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: i)
        forget(item)
        if deleteFiles {
            for url in Set([item.url] + [item.savedURL].compactMap { $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        save()
    }

    /// Drops every entry. Temp files are deleted; files in the user's save folder are left alone.
    func clear() {
        let temp = FileStore.temporaryDirectory.standardizedFileURL.path
        for item in items {
            forget(item)
            if item.url.standardizedFileURL.path.hasPrefix(temp) {
                try? FileManager.default.removeItem(at: item.url)
            }
        }
        items.removeAll()
        save()
    }

    /// Removes entries whose file no longer exists (temp cleanup, user deleted it in Finder…).
    /// Entries whose temp file is gone but whose saved copy exists are re-pointed at the copy.
    func pruneMissing() {
        var changed = false
        items.removeAll { item in
            let fm = FileManager.default
            if fm.fileExists(atPath: item.url.path) { return false }
            if let saved = item.savedURL, fm.fileExists(atPath: saved.path) {
                item.url = saved
                changed = true
                return false
            }
            forget(item)
            changed = true
            return true
        }
        if changed { save() }
    }

    // MARK: Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? decoder.decode([Record].self, from: data) else { return }
        var seen = Set<UUID>()
        var loaded: [CaptureItem] = []
        for record in records where !seen.contains(record.id) {
            let fm = FileManager.default
            var record = record
            if !fm.fileExists(atPath: record.url.path) {
                guard let saved = record.savedURL, fm.fileExists(atPath: saved.path) else { continue }
                record = Record(record, url: saved)
            }
            seen.insert(record.id)
            loaded.append(CaptureItem(restoring: record))
        }
        loaded.sort { $0.createdAt < $1.createdAt }
        if loaded.count > Self.capacity { loaded.removeFirst(loaded.count - Self.capacity) }
        items = loaded
        items.forEach(observe)
        if loaded.count != records.count { save() }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items.map { Record($0) })
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("HistoryStore: couldn't save history: \(error)")
        }
    }

    /// Coalesces the bursts of metadata changes (savedURL, size, duration) into one write.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.save()
        }
    }

    /// Re-saves whenever a field we persist changes on the item (Save / Save As / editor export…).
    private func observe(_ item: CaptureItem) {
        guard observers[item.id] == nil else { return }
        let changes = item.$savedURL.map { _ in () }
            .merge(with: item.$url.map { _ in () }, item.$pixelSize.map { _ in () }, item.$duration.map { _ in () })
            .dropFirst(4)
        observers[item.id] = changes.sink { [weak self] in self?.scheduleSave() }
    }

    private func forget(_ item: CaptureItem) {
        observers[item.id] = nil
    }

    /// Keeps only the most recent captures' full images resident: the item that just aged out of
    /// that window drops its image (it reloads lazily from disk when needed again).
    private func evictOldImage() {
        let index = items.count - Self.inMemoryImageCount - 1
        guard index >= 0, items[index].isImage else { return }
        items[index].releaseCachedImages()
    }
}

private extension HistoryStore.Record {
    /// Copy with the file location replaced (used when the temp file is gone but the saved copy remains).
    init(_ r: HistoryStore.Record, url: URL) {
        id = r.id
        kind = r.kind
        self.url = url
        savedURL = r.savedURL
        createdAt = r.createdAt
        pixelScale = r.pixelScale
        pixelWidth = r.pixelWidth
        pixelHeight = r.pixelHeight
        sourceRect = r.sourceRect
        duration = r.duration
    }
}
