import AppKit
import AVFoundation

/// One capture result (still image, video or GIF) that lives in a temp file until saved.
/// Items restored from the history store load their image and thumbnail lazily from disk.
@MainActor
final class CaptureItem: ObservableObject, Identifiable {
    enum Kind: String, Codable {
        case image
        case video
        case gif

        /// Short label for badges ("Image", "Video", "GIF").
        var title: String {
            switch self {
            case .image: return "Image"
            case .video: return "Video"
            case .gif: return "GIF"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let createdAt: Date
    let pixelScale: CGFloat
    /// Where on screen (Cocoa coordinates) the image was captured from, if known.
    var sourceRect: CGRect?
    /// Current on-disk location (temp folder until saved).
    @Published var url: URL
    @Published var savedURL: URL?
    @Published var isBusy = false
    @Published var duration: TimeInterval?
    /// Size in pixels; known immediately for images, loaded asynchronously for video and GIF.
    @Published var pixelSize: CGSize?
    @Published private var cachedThumbnail: NSImage?
    private var cachedImage: CGImage?
    private var thumbnailTask: Task<Void, Never>?

    var isVideo: Bool { kind == .video }
    var isImage: Bool { kind == .image }

    /// The full-resolution image, loaded from disk on first access for restored (or evicted) items.
    var image: CGImage? {
        guard kind == .image else { return nil }
        if cachedImage == nil { cachedImage = CGImage.load(from: fileURL) }
        return cachedImage
    }

    /// Preview image. Reading it before one exists kicks off an asynchronous load; the published
    /// backing value updates once the thumbnail is ready.
    var thumbnail: NSImage? {
        get {
            if cachedThumbnail == nil { requestThumbnail() }
            return cachedThumbnail
        }
        set { cachedThumbnail = newValue }
    }

    /// The file to read from: the temp file while it exists, otherwise the saved copy.
    var fileURL: URL {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return savedURL ?? url
    }

    /// Writes the image to the temp folder in the user's preferred format.
    init(image: CGImage, pixelScale: CGFloat, date: Date = .now) throws {
        let format = Preferences.fileFormat
        let url = FileStore.temporaryURL(ext: format.fileExtension, date: date)
        try FileStore.write(image, to: url, format: format, pixelScale: pixelScale)
        self.id = UUID()
        self.kind = .image
        self.pixelScale = pixelScale
        self.createdAt = date
        self.url = url
        self.cachedImage = image
        self.cachedThumbnail = image.nsImage
        self.pixelSize = CGSize(width: image.width, height: image.height)
    }

    init(videoURL: URL, pixelScale: CGFloat, date: Date = .now) {
        self.id = UUID()
        self.kind = .video
        self.pixelScale = pixelScale
        self.createdAt = date
        self.url = videoURL
        Task { await loadVideoMetadata() }
    }

    init(gifURL: URL, pixelScale: CGFloat, date: Date = .now) {
        self.id = UUID()
        self.kind = .gif
        self.pixelScale = pixelScale
        self.createdAt = date
        self.url = gifURL
        if let img = CGImage.load(from: gifURL) {
            cachedThumbnail = img.nsImage
            pixelSize = CGSize(width: img.width, height: img.height)
        }
    }

    /// Restores an item from a persisted history record. Nothing is read from disk until needed.
    init(restoring record: HistoryStore.Record) {
        self.id = record.id
        self.kind = record.kind
        self.pixelScale = record.pixelScale
        self.createdAt = record.createdAt
        self.url = record.url
        self.savedURL = record.savedURL
        self.sourceRect = record.sourceRect
        self.duration = record.duration
        if let w = record.pixelWidth, let h = record.pixelHeight {
            self.pixelSize = CGSize(width: w, height: h)
        }
    }

    /// Drops the in-memory full image and thumbnail so old history entries don't pin memory.
    /// Both are reloaded from disk (thumbnail downscaled) the next time they're read.
    func releaseCachedImages() {
        cachedImage = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        cachedThumbnail = nil
    }

    // MARK: Lazy loading

    private func requestThumbnail() {
        guard thumbnailTask == nil else { return }
        let source = fileURL
        let kind = kind
        thumbnailTask = Task { [weak self] in
            let result: (NSImage, CGSize)?
            switch kind {
            case .image, .gif: result = await Self.loadImageThumbnail(from: source)
            case .video: result = await Self.loadVideoThumbnail(from: source)
            }
            guard let self, !Task.isCancelled else { return }
            if let result {
                cachedThumbnail = result.0
                if pixelSize == nil { pixelSize = result.1 }
            }
            thumbnailTask = nil
        }
    }

    /// Downscaled thumbnail plus the full pixel size, decoded off the main thread.
    private nonisolated static func loadImageThumbnail(from url: URL) async -> (NSImage, CGSize)? {
        await Task.detached(priority: .utility) { () -> (NSImage, CGSize)? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            var size = CGSize.zero
            if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat {
                size = CGSize(width: w, height: h)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            if size == .zero { size = CGSize(width: thumb.width, height: thumb.height) }
            return (thumb.nsImage, size)
        }.value
    }

    private nonisolated static func loadVideoThumbnail(from url: URL) async -> (NSImage, CGSize)? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 512, height: 512)
        guard let result = try? await gen.image(at: .zero) else { return nil }
        let size = await Self.videoPixelSize(of: asset) ?? CGSize(width: result.image.width, height: result.image.height)
        return (result.image.nsImage, size)
    }

    private nonisolated static func videoPixelSize(of asset: AVURLAsset) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: loaded.0).applying(loaded.1)
        return CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
    }

    /// Duration and pixel size for a fresh recording; the thumbnail comes through the lazy path.
    private func loadVideoMetadata() async {
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration) { duration = d.seconds }
        if let size = await Self.videoPixelSize(of: asset) { pixelSize = size }
    }
}
