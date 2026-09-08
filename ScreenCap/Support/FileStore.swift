import AppKit

enum FileStore {
    static let temporaryDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenCap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    static func fileName(ext: String, date: Date = .now) -> String {
        "ScreenCap \(dateFormatter.string(from: date)).\(ext)"
    }

    static func temporaryURL(ext: String, date: Date = .now) -> URL {
        uniqueURL(in: temporaryDirectory, fileName: fileName(ext: ext, date: date))
    }

    /// Appends " (2)", " (3)"… until the name is free.
    static func uniqueURL(in directory: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    static func write(_ image: CGImage, to url: URL, format: ImageFormat, pixelScale: CGFloat) throws {
        guard let data = image.encoded(as: format, pixelScale: pixelScale) else {
            throw CaptureError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    /// Copies a capture's file into the user's save folder and returns the destination.
    @MainActor @discardableResult
    static func saveToUserFolder(_ item: CaptureItem) throws -> URL {
        let dir = Preferences.saveDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = uniqueURL(in: dir, fileName: item.url.lastPathComponent)
        try FileManager.default.copyItem(at: item.url, to: dest)
        item.savedURL = dest
        return dest
    }

    static func saveToUserFolder(image: CGImage, pixelScale: CGFloat, date: Date = .now) throws -> URL {
        let dir = Preferences.saveDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let format = Preferences.fileFormat
        let dest = uniqueURL(in: dir, fileName: fileName(ext: format.fileExtension, date: date))
        try write(image, to: dest, format: format, pixelScale: pixelScale)
        return dest
    }

    /// Temp captures older than a day are removed on launch.
    static func cleanupTemporaryFiles(olderThan age: TimeInterval = 86_400) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for f in files {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: f) }
        }
    }
}

enum CaptureError: LocalizedError {
    case displayNotFound
    case windowNotFound
    case encodingFailed
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "Couldn't find the display to capture."
        case .windowNotFound: return "That window is no longer available."
        case .encodingFailed: return "Couldn't encode the image."
        case .recordingFailed(let why): return "Recording failed: \(why)"
        }
    }
}
