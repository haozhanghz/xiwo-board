import AVFoundation

/// Joins the parts of a paused recording into one file, back to back, so the paused
/// time is left out. Each part's tracks keep their offsets from the part's start and
/// the next part starts where the longest track of this one ends, so sound and picture
/// stay together however many times the recording was paused.
enum RecordingMerger {
    static func merge(_ parts: [URL], into output: URL) async throws {
        let composition = AVMutableComposition()
        // The n-th track of each media type in every part goes to the n-th composition
        // track of that type, so parts with several sound tracks keep them apart.
        var targets: [String: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero
        for part in parts {
            let asset = AVURLAsset(url: part)
            let duration = try await asset.load(.duration)
            guard duration > .zero else { continue }
            var seen: [AVMediaType: Int] = [:]
            // Picture and sound only; anything else a part may carry is left out.
            for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
                let n = seen[track.mediaType, default: 0]
                seen[track.mediaType] = n + 1
                let key = "\(track.mediaType.rawValue)-\(n)"
                guard let target = targets[key]
                        ?? composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw MergeError.cannotJoin }
                targets[key] = target
                let range = try await track.load(.timeRange)
                try target.insertTimeRange(range, of: track, at: cursor + range.start)
            }
            cursor = cursor + duration
        }
        guard cursor > .zero else { throw MergeError.empty }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MergeError.cannotJoin
        }
        try? FileManager.default.removeItem(at: output)
        try await export.export(to: output, as: .mp4)
    }

    enum MergeError: LocalizedError {
        case empty, cannotJoin
        var errorDescription: String? {
            switch self {
            case .empty: return "录制的片段都是空的。"
            case .cannotJoin: return "录制的片段无法合并成一个视频。"
            }
        }
    }
}
