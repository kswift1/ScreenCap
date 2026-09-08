import AppKit
import AVFoundation

/// One capture result (still image or video) that lives in a temp file until saved.
@MainActor
final class CaptureItem: ObservableObject, Identifiable {
    enum Kind {
        case image(CGImage)
        case video
        case gif
    }

    let id = UUID()
    let kind: Kind
    let createdAt: Date
    let pixelScale: CGFloat
    /// Current on-disk location (temp folder until saved).
    @Published var url: URL
    @Published var savedURL: URL?
    @Published var thumbnail: NSImage?
    @Published var isBusy = false
    @Published var duration: TimeInterval?

    var isVideo: Bool { if case .video = kind { return true } else { return false } }
    var isImage: Bool { if case .image = kind { return true } else { return false } }
    var image: CGImage? { if case .image(let img) = kind { return img } else { return nil } }

    /// Writes the image to the temp folder in the user's preferred format.
    init(image: CGImage, pixelScale: CGFloat, date: Date = .now) throws {
        let format = Preferences.fileFormat
        let url = FileStore.temporaryURL(ext: format.fileExtension, date: date)
        try FileStore.write(image, to: url, format: format, pixelScale: pixelScale)
        self.kind = .image(image)
        self.pixelScale = pixelScale
        self.createdAt = date
        self.url = url
        self.thumbnail = image.nsImage
    }

    init(videoURL: URL, pixelScale: CGFloat, date: Date = .now) {
        self.kind = .video
        self.pixelScale = pixelScale
        self.createdAt = date
        self.url = videoURL
        Task { await loadVideoMetadata() }
    }

    init(gifURL: URL, pixelScale: CGFloat, date: Date = .now) {
        self.kind = .gif
        self.pixelScale = pixelScale
        self.createdAt = date
        self.url = gifURL
        if let img = CGImage.load(from: gifURL) { thumbnail = img.nsImage }
    }

    private func loadVideoMetadata() async {
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration) { duration = d.seconds }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 800, height: 800)
        if let result = try? await gen.image(at: .zero) {
            thumbnail = result.image.nsImage
        }
    }
}
