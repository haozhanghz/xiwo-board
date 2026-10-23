import AVFoundation
import os

private let log = Logger(subsystem: "io.github.haozhanghz.xiwoboard", category: "merger")

/// The joined file's samples for one track, in the order the writer takes them.
private protocol MergeFeed: AnyObject {
    func next() throws -> CMSampleBuffer?
}

/// Joins the parts of a paused recording into one file, back to back, so the paused
/// time is left out.
///
/// Each part's picture is copied as recorded, only moved along the timeline so the
/// part starts where the one before it ended; its sound is decoded and written again
/// as one continuous track per source, with silence where a part has none. The result
/// is a single plain timeline that every player and editor reads the same way.
enum RecordingMerger {
    static func merge(_ parts: [URL], into output: URL) async throws {
        do {
            try await join(parts, into: output)
        } catch MergeError.empty {
            throw MergeError.empty
        } catch {
            // Parts the copy cannot take, such as pictures of different sizes, still make
            // a file that plays: one that strings the parts together with an edit list.
            log.error("Joining by copying failed, using an edit list: \(String(describing: error), privacy: .public)")
            try await compose(parts, into: output)
        }
    }

    /// A part and the stretch of it that goes into the joined file.
    struct Part {
        var asset: AVURLAsset
        var picture: AVAssetTrack?
        /// Picture samples come out of a reader stamped with their media times; this much
        /// later than where the track's edit shows them.
        var pictureDelay: CMTime = .zero
        var sound: [AVAssetTrack]
        /// The picture's time range, or the whole part when it has no picture.
        var window: CMTimeRange
        /// Where the window starts in the joined file.
        var start: CMTime = .zero
        var end: CMTime { start + window.duration }
    }

    static func join(_ urls: [URL], into output: URL) async throws {
        var parts: [Part] = []
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.load(.tracks)
            let picture = tracks.first { $0.mediaType == .video }
            // Sound tracks keep their order, so the n-th of every part goes to the n-th joined track.
            let sound = tracks.filter { $0.mediaType == .audio }
            let window: CMTimeRange
            var delay = CMTime.zero
            if let picture {
                window = try await picture.load(.timeRange)
                // A picture recorded in one go is shown as one stretch of its media; other
                // edits are left to the composition.
                let shown = try await picture.load(.segments).filter { !$0.isEmpty }
                guard shown.count == 1, shown[0].timeMapping.source.duration == shown[0].timeMapping.target.duration
                else { throw MergeError.cannotJoin }
                delay = shown[0].timeMapping.source.start - shown[0].timeMapping.target.start
            } else {
                window = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            }
            guard window.duration.isNumeric, window.duration > .zero else { continue }
            parts.append(Part(asset: asset, picture: picture, pictureDelay: delay, sound: sound, window: window, start: cursor))
            cursor = cursor + window.duration
            // A part paused just after a new frame came in still shows that frame for a moment.
            if let picture, let last = try await lastShown(picture, delay: delay) {
                cursor = CMTimeMaximum(cursor, parts[parts.count - 1].start + (last - window.start) + shortestFrame)
            }
        }
        guard !parts.isEmpty else { throw MergeError.empty }
        // With reordered frames the picture starts decoding a little before its first frame
        // is shown. Start the joined timeline that much later, so no decode time falls before
        // zero, and let the writer trim the lead with an edit, as the recorder's own files do.
        let lead = try decodeLead(of: parts[0])
        for i in parts.indices { parts[i].start = parts[i].start + lead }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        var feeds: [(AVAssetWriterInput, MergeFeed)] = []
        if let first = parts.lazy.compactMap(\.picture).first {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                           sourceFormatHint: try await first.load(.formatDescriptions).first)
            input.transform = try await first.load(.preferredTransform)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw MergeError.cannotJoin }
            writer.add(input)
            feeds.append((input, PictureFeed(parts: parts, tick: CMTime(value: 1, timescale: try await first.load(.naturalTimeScale)))))
        }
        for n in 0..<(parts.map(\.sound.count).max() ?? 0) {
            let source = parts.lazy.compactMap { $0.sound.count > n ? $0.sound[n] : nil }.first!
            let format = try await source.load(.formatDescriptions).first
            let sourceChannels = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
            let channels = Int(min(2, max(1, sourceChannels)))
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: SoundFeed.rate, AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw MergeError.cannotJoin }
            writer.add(input)
            feeds.append((input, try SoundFeed(parts: parts, track: n, channels: channels)))
        }
        guard !feeds.isEmpty else { throw MergeError.empty }

        guard writer.startWriting() else { throw writer.error ?? MergeError.cannotJoin }
        writer.startSession(atSourceTime: lead)
        do {
            try await pump(feeds, writer: writer)
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        // Like the parts, the joined file ends where the recording stopped, not a frame later.
        writer.endSession(atSourceTime: parts[parts.count - 1].end)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MergeError.cannotJoin }
    }

    /// The least time a frame stays on screen where one part meets the next: one refresh
    /// at 60 Hz. Tools that round frame times to the frame rate, such as FFmpeg when it
    /// converts the video, would put two frames closer together than that at one moment.
    static let shortestFrame = CMTime(value: 1, timescale: 60)

    /// When the part's last frame is shown, on its track's timeline, found from the file's
    /// sample table; nil if the file has none to look in.
    private static func lastShown(_ track: AVAssetTrack, delay: CMTime) async throws -> CMTime? {
        guard try await track.load(.canProvideSampleCursors),
              let cursor = track.makeSampleCursorAtLastSampleInDecodeOrder() else { return nil }
        // With reordered frames the last one shown is among the last few decoded.
        var latest = cursor.presentationTimeStamp
        for _ in 0..<16 {
            guard cursor.stepInDecodeOrder(byCount: -1) == -1 else { break }
            latest = CMTimeMaximum(latest, cursor.presentationTimeStamp)
        }
        return latest.isNumeric ? latest - delay : nil
    }

    /// How long before its first shown frame the part's picture starts decoding.
    private static func decodeLead(of part: Part) throws -> CMTime {
        guard let track = part.picture else { return .zero }
        let reader = try AVAssetReader(asset: part.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw MergeError.cannotJoin }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MergeError.cannotJoin }
        defer { reader.cancelReading() }
        while let buffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            let decode = CMSampleBufferGetDecodeTimeStamp(buffer) - part.pictureDelay
            return decode.isValid && decode < part.window.start ? part.window.start - decode : .zero
        }
        return .zero
    }

    /// Feeds every input whenever it is ready for more. The writer interleaves the tracks
    /// and holds back an input that runs ahead, so all are fed in turn.
    private static func pump(_ feeds: [(AVAssetWriterInput, MergeFeed)], writer: AVAssetWriter) async throws {
        var open = Set(feeds.indices)
        while !open.isEmpty {
            var progressed = false
            for i in open.sorted() {
                let (input, feed) = feeds[i]
                while input.isReadyForMoreMediaData {
                    progressed = true
                    guard let buffer = try feed.next() else {
                        input.markAsFinished()
                        open.remove(i)
                        break
                    }
                    guard input.append(buffer) else { throw writer.error ?? MergeError.cannotJoin }
                }
            }
            if writer.status == .failed { throw writer.error ?? MergeError.cannotJoin }
            if !progressed { try await Task.sleep(nanoseconds: 2_000_000) }
        }
    }

    /// Every part's picture samples as recorded, in decode order, moved so each part
    /// starts where the one before it ended.
    private final class PictureFeed: MergeFeed {
        private let parts: [Part]
        private let tick: CMTime
        private var index = -1
        private var reader: AVAssetReader?
        private var output: AVAssetReaderTrackOutput?
        private var shift = CMTime.zero
        /// Where the current part's frames go in the joined file.
        private var shown = CMTimeRange.zero
        private var lastDecode: CMTime?

        init(parts: [Part], tick: CMTime) {
            self.parts = parts
            self.tick = tick.isValid && tick > .zero ? tick : CMTime(value: 1, timescale: 600)
        }

        func next() throws -> CMSampleBuffer? {
            while true {
                if let reader, let output {
                    if let buffer = output.copyNextSampleBuffer() {
                        guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
                        return try moved(buffer)
                    }
                    if reader.status == .failed { throw reader.error ?? MergeError.cannotJoin }
                    self.reader = nil
                    self.output = nil
                }
                index += 1
                guard index < parts.count else { return nil }
                let part = parts[index]
                guard let track = part.picture else { continue }
                let r = try AVAssetReader(asset: part.asset)
                let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                o.alwaysCopiesSampleData = false
                guard r.canAdd(o) else { throw MergeError.cannotJoin }
                r.add(o)
                guard r.startReading() else { throw r.error ?? MergeError.cannotJoin }
                reader = r
                output = o
                shift = part.start - part.window.start - part.pictureDelay
                shown = CMTimeRange(start: part.start, duration: part.window.duration)
            }
        }

        private func moved(_ buffer: CMSampleBuffer) throws -> CMSampleBuffer {
            var count: CMItemCount = 0
            CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
            guard count > 0 else { throw MergeError.cannotJoin }
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
            guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr
            else { throw MergeError.cannotJoin }
            for i in timing.indices {
                let presentation = timing[i].presentationTimeStamp + shift
                // A frame the part's own edit leaves out would land on its neighbour; the
                // composition takes parts like that.
                guard CMTimeRangeContainsTime(shown, time: presentation) else { throw MergeError.cannotJoin }
                timing[i].presentationTimeStamp = presentation
                var decode = timing[i].decodeTimeStamp.isValid ? timing[i].decodeTimeStamp + shift : presentation
                // A part's first frames can decode slightly before the previous part's last
                // ones (frames are reordered for compression); keep decode order moving forward.
                if let last = lastDecode, decode <= last { decode = last + tick }
                if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = decode }
                lastDecode = decode
            }
            var out: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: timing.count,
                                                               sampleTimingArray: &timing, sampleBufferOut: &out)
            guard status == noErr, let out else { throw MergeError.cannotJoin }
            return out
        }
    }

    /// One joined sound track: for each part, its sound for the part's window, decoded,
    /// and silence wherever the part has no such track or its sound starts late or ends early.
    private final class SoundFeed: MergeFeed {
        static let rate = 48_000
        private let parts: [Part]
        private let track: Int
        private let channels: Int
        private let format: CMAudioFormatDescription
        private var bytesPerFrame: Int { channels * 2 }
        private var index = -1
        private var reader: AVAssetReader?
        private var output: AVAssetReaderTrackOutput?
        /// The frame the next sound written starts at.
        private var written: Int
        private var pending: [CMSampleBuffer] = []

        init(parts: [Part], track: Int, channels: Int) throws {
            self.parts = parts
            self.track = track
            self.channels = channels
            written = Self.frame(at: parts[0].start)
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Double(Self.rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2),
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
            var description: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
            guard let description else { throw MergeError.cannotJoin }
            format = description
        }

        static func frame(at time: CMTime) -> Int { Int((time.seconds * Double(rate)).rounded()) }

        func next() throws -> CMSampleBuffer? {
            while pending.isEmpty {
                if let reader, let output {
                    if let buffer = output.copyNextSampleBuffer() {
                        try place(buffer, part: parts[index])
                        continue
                    }
                    if reader.status == .failed { throw reader.error ?? MergeError.cannotJoin }
                    self.reader = nil
                    self.output = nil
                    try silence(until: Self.frame(at: parts[index].end))
                    continue
                }
                index += 1
                guard index < parts.count else { return nil }
                let part = parts[index]
                guard part.sound.count > track else {
                    try silence(until: Self.frame(at: part.end))
                    continue
                }
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
                let r = try AVAssetReader(asset: part.asset)
                r.timeRange = part.window
                let o = AVAssetReaderTrackOutput(track: part.sound[track], outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: channels,
                    AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                guard r.canAdd(o) else { throw MergeError.cannotJoin }
                r.add(o)
                guard r.startReading() else { throw r.error ?? MergeError.cannotJoin }
                reader = r
                output = o
            }
            return pending.removeFirst()
        }

        /// Puts decoded sound where it belongs in the joined track: silence first if it
        /// starts after what was written, cut where it overlaps that or runs past the part.
        private func place(_ buffer: CMSampleBuffer, part: Part) throws {
            let count = CMSampleBufferGetNumSamples(buffer)
            guard count > 0, let block = CMSampleBufferGetDataBuffer(buffer) else { return }
            let first = Self.frame(at: part.start + (CMSampleBufferGetPresentationTimeStamp(buffer) - part.window.start))
            let skip = max(0, written - first)
            let keep = min(count, Self.frame(at: part.end) - first) - skip
            guard keep > 0 else { return }
            try silence(until: first + skip)
            var bytes = Data(count: keep * bytesPerFrame)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: skip * bytesPerFrame, dataLength: keep * bytesPerFrame, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw MergeError.cannotJoin }
            try emit(bytes)
        }

        private func silence(until frame: Int) throws {
            while written < frame {
                try emit(Data(count: min(frame - written, Self.rate / 10) * bytesPerFrame))
            }
        }

        private func emit(_ bytes: Data) throws {
            let frames = bytes.count / bytesPerFrame
            guard frames > 0 else { return }
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                                                            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard status == noErr, let block else { throw MergeError.cannotJoin }
            status = bytes.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
            }
            guard status == noErr else { throw MergeError.cannotJoin }
            var sample: CMSampleBuffer?
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(Self.rate)),
                packetDescriptions: nil, sampleBufferOut: &sample)
            guard status == noErr, let sample else { throw MergeError.cannotJoin }
            pending.append(sample)
            written += frames
        }
    }

    /// Strings the parts together with a composition: each part's tracks keep their offsets
    /// from the part's start, and the next part starts where the longest track of this one ends.
    static func compose(_ parts: [URL], into output: URL) async throws {
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
