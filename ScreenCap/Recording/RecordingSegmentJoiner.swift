import AVFoundation

/// Concatenates recording segments (one file per pause/resume span) into a single mp4.
/// Video and audio tracks are copied back-to-back with a passthrough export, so no re-encoding.
enum RecordingSegmentJoiner {
    enum JoinError: LocalizedError {
        case noSegments, exportUnavailable
        var errorDescription: String? {
            switch self {
            case .noSegments: return "There are no recording segments to join."
            case .exportUnavailable: return "Couldn't create the export session."
            }
        }
    }

    static func join(_ segments: [URL], to output: URL) async throws {
        guard !segments.isEmpty else { throw JoinError.noSegments }
        let composition = AVMutableComposition()
        var compositionTracks: [String: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero

        for url in segments {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            var indexByType: [AVMediaType: Int] = [:]
            for track in tracks {
                let type = track.mediaType
                guard type == .video || type == .audio else { continue }
                let index = indexByType[type, default: 0]
                indexByType[type] = index + 1
                let key = "\(type.rawValue)#\(index)"
                let target: AVMutableCompositionTrack
                if let existing = compositionTracks[key] {
                    target = existing
                } else if let created = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    target = created
                    compositionTracks[key] = created
                    if type == .video {
                        created.preferredTransform = try await track.load(.preferredTransform)
                    }
                } else {
                    continue
                }
                try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: cursor)
            }
            cursor = cursor + duration
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw JoinError.exportUnavailable
        }
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: .mp4)
    }
}
