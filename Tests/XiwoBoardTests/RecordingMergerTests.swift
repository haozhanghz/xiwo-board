import AVFoundation
import XCTest
@testable import XiwoBoard

/// Joining the parts of a paused recording: the result is as long as the parts
/// together, and each moment keeps its own picture and sound.
final class RecordingMergerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("merger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Like a recording with microphone and system audio that was paused twice: a red
    /// silent second, half a second of green with a tone, then a silent blue second and a half.
    func testJoinsPartsBackToBackWithSoundInStep() async throws {
        let specs: [(seconds: Double, color: Pixel, loud: Bool)] = [
            (1.0, Pixel(r: 220, g: 30, b: 30), false),
            (0.5, Pixel(r: 30, g: 200, b: 30), true),
            (1.5, Pixel(r: 30, g: 30, b: 220), false),
        ]
        var parts: [URL] = []
        for (i, spec) in specs.enumerated() {
            let url = dir.appendingPathComponent("part\(i).mp4")
            try await Self.writePart(to: url, seconds: spec.seconds, color: spec.color, loud: spec.loud, soundTracks: 2)
            parts.append(url)
        }
        let joined = dir.appendingPathComponent("joined.mp4")
        try await RecordingMerger.merge(parts, into: joined)

        let asset = AVURLAsset(url: joined)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 3.0, accuracy: 0.1)
        let video = try await asset.loadTracks(withMediaType: .video)
        let sound = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(sound.count, 2)

        for (time, part) in [(0.5, 0), (1.25, 1), (2.25, 2)] {
            let pixel = try await Self.pixel(of: asset, at: time)
            XCTAssertEqual(pixel.leadingChannel, specs[part].color.leadingChannel,
                           "picture at \(time) s is \(pixel), expected part \(part + 1)")
            for track in sound {
                let level = try Self.loudness(of: asset, track: track, from: time - 0.15, to: time + 0.15)
                if specs[part].loud {
                    XCTAssertGreaterThan(level, 2000, "no tone at \(time) s")
                } else {
                    XCTAssertLessThan(level, 300, "sound at \(time) s belongs to another part")
                }
            }
        }
    }

    /// Parts whose frames are reordered for compression, as ScreenCaptureKit's are: the
    /// joined picture is one timeline that decodes in rising order, so tools other than
    /// AVFoundation, such as FFmpeg and video editors, read it the same way.
    func testJoinedPictureIsOneSteadyTimeline() async throws {
        var parts: [URL] = []
        var frames = 0
        for (i, seconds) in [1.0, 0.5, 1.5].enumerated() {
            let url = dir.appendingPathComponent("part\(i).mp4")
            try await Self.writePart(to: url, seconds: seconds, color: Pixel(r: 40, g: 40 + 80 * i, b: 200), loud: false,
                                     soundTracks: 1, reorderFrames: true)
            parts.append(url)
            frames += Int(seconds * 30)
        }
        let joined = dir.appendingPathComponent("joined.mp4")
        try await RecordingMerger.join(parts, into: joined)

        let asset = AVURLAsset(url: joined)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let segments = try await video.load(.segments)
        XCTAssertEqual(segments.count, 1, "the picture should play as one stretch")
        let mapping = try XCTUnwrap(segments.first { !$0.isEmpty }).timeMapping
        XCTAssertEqual(mapping.target.start.seconds, 0, accuracy: 0.001, "the picture starts late")
        // The reader gives the times stored in the file; the edit places them on the track.
        let lead = mapping.source.start.seconds - mapping.target.start.seconds
        let times = try Self.sampleTimes(of: asset, track: video).map { (presentation: $0.presentation - lead, decode: $0.decode - lead) }
        XCTAssertEqual(times.count, frames)
        XCTAssertTrue(times.contains { $0.decode < $0.presentation - 0.001 }, "the parts had no reordered frames to test with")
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertLessThan(a.decode, b.decode, "decode order goes back")
        }
        let shown = times.map(\.presentation).sorted()
        XCTAssertEqual(shown[0], 0, accuracy: 0.001)
        for (a, b) in zip(shown, shown.dropFirst()) {
            XCTAssertEqual(b - a, 1.0 / 30, accuracy: 0.002, "a gap or an overlap at \(a) s")
        }
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 3.0, accuracy: 0.05)
    }

    /// Parts paused just after a new frame came in, as when the board changes right before
    /// the pause: that frame still gets a moment of its own, so tools that round frame times
    /// to the frame rate see every frame once, and sound stays with its picture.
    func testFrameJustBeforeAPauseKeepsAMomentOfItsOwn() async throws {
        let specs: [(color: Pixel, loud: Bool)] = [
            (Pixel(r: 220, g: 30, b: 30), true), (Pixel(r: 30, g: 200, b: 30), false), (Pixel(r: 30, g: 30, b: 220), true),
        ]
        var parts: [URL] = []
        for (i, spec) in specs.enumerated() {
            let url = dir.appendingPathComponent("part\(i).mp4")
            try await Self.writePart(to: url, seconds: 0.5, color: spec.color, loud: spec.loud, soundTracks: 1,
                                     stopsJustAfterLastFrame: true)
            parts.append(url)
        }
        let joined = dir.appendingPathComponent("joined.mp4")
        try await RecordingMerger.join(parts, into: joined)

        let asset = AVURLAsset(url: joined)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let segments = try await video.load(.segments)
        let mapping = try XCTUnwrap(segments.first { !$0.isEmpty }).timeMapping
        let lead = mapping.source.start.seconds - mapping.target.start.seconds
        let shown = try Self.sampleTimes(of: asset, track: video).map { $0.presentation - lead }.sorted()
        XCTAssertEqual(shown.count, 45)
        for (a, b) in zip(shown, shown.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 1.0 / 60 - 0.0001, "two frames almost at once at \(a) s")
        }
        // Each part lasts 14/30 s and 1/600 s; each join gives the last frame 1/60 s.
        let part = 14.0 / 30 + 1.0 / 600, join = 14.0 / 30 + 1.0 / 60
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2 * join + part, accuracy: 0.002)
        let sound = try await asset.loadTracks(withMediaType: .audio)
        for (i, spec) in specs.enumerated() {
            let middle = Double(i) * join + part / 2
            let pixel = try await Self.pixel(of: asset, at: middle)
            XCTAssertEqual(pixel.leadingChannel, spec.color.leadingChannel, "picture at \(middle) s is \(pixel)")
            let level = try Self.loudness(of: asset, track: sound[0], from: middle - 0.1, to: middle + 0.1)
            if spec.loud {
                XCTAssertGreaterThan(level, 2000, "no tone at \(middle) s")
            } else {
                XCTAssertLessThan(level, 300, "sound at \(middle) s belongs to another part")
            }
        }
    }

    /// A part with no sound (the microphone was off then, say) is filled with silence,
    /// so the sound of the later parts stays with their picture.
    func testPartWithoutSoundGetsSilence() async throws {
        let specs: [(seconds: Double, color: Pixel, sound: Int)] = [
            (1.0, Pixel(r: 220, g: 30, b: 30), 1),
            (0.5, Pixel(r: 30, g: 200, b: 30), 0),
            (1.0, Pixel(r: 30, g: 30, b: 220), 1),
        ]
        var parts: [URL] = []
        for (i, spec) in specs.enumerated() {
            let url = dir.appendingPathComponent("part\(i).mp4")
            try await Self.writePart(to: url, seconds: spec.seconds, color: spec.color, loud: true, soundTracks: spec.sound)
            parts.append(url)
        }
        let joined = dir.appendingPathComponent("joined.mp4")
        try await RecordingMerger.join(parts, into: joined)
        let asset = AVURLAsset(url: joined)
        let sound = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(sound.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2.5, accuracy: 0.05)
        XCTAssertGreaterThan(try Self.loudness(of: asset, track: sound[0], from: 0.4, to: 0.7), 2000)
        XCTAssertLessThan(try Self.loudness(of: asset, track: sound[0], from: 1.1, to: 1.4), 300)
        XCTAssertGreaterThan(try Self.loudness(of: asset, track: sound[0], from: 1.8, to: 2.2), 2000)
        let pixel = try await Self.pixel(of: asset, at: 1.25)
        XCTAssertEqual(pixel.leadingChannel, 1)
    }

    /// A voice that came in quiet is raised to the speaking level, picture untouched.
    func testRaisesQuietSound() async throws {
        let part = dir.appendingPathComponent("quiet.mp4")
        try await Self.writePart(to: part, seconds: 2, color: Pixel(r: 30, g: 200, b: 30), loud: true, soundTracks: 1, amplitude: 1_200)
        let levelled = dir.appendingPathComponent("levelled.mp4")
        let raised = try await RecordingMerger.level(part, into: levelled)
        XCTAssertTrue(raised)

        let asset = AVURLAsset(url: levelled)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.05)
        let sound = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(sound.count, 1)
        // -16 dBFS is 5196 in 16-bit units; the tone started at 849.
        let level = try Self.loudness(of: asset, track: sound[0], from: 0.5, to: 1.5)
        XCTAssertEqual(level, 5196, accuracy: 400)
        let pixel = try await Self.pixel(of: asset, at: 1)
        XCTAssertEqual(pixel.leadingChannel, 1)
    }

    /// Sound already at a speaking level, and silence, are left as recorded.
    func testLeavesLoudSoundAndSilenceAlone() async throws {
        for loud in [true, false] {
            let part = dir.appendingPathComponent("part-\(loud).mp4")
            try await Self.writePart(to: part, seconds: 1, color: Pixel(r: 220, g: 30, b: 30), loud: loud, soundTracks: 1)
            let levelled = dir.appendingPathComponent("levelled-\(loud).mp4")
            let raised = try await RecordingMerger.level(part, into: levelled)
            XCTAssertFalse(raised)
            XCTAssertFalse(FileManager.default.fileExists(atPath: levelled.path))
        }
    }

    /// Peaks the gain would push past full scale are rounded off, not wrapped or clipped hard.
    func testRaisedPeaksStayInRange() {
        XCTAssertEqual(RecordingMerger.Leveler.raise(1_000, by: 2), 2_000)
        XCTAssertEqual(RecordingMerger.Leveler.raise(-1_000, by: 2), -2_000)
        let loud = RecordingMerger.Leveler.raise(30_000, by: 4)
        XCTAssertGreaterThan(loud, 30_000)
        XCTAssertLessThanOrEqual(loud, 32_767)
        XCTAssertLessThan(RecordingMerger.Leveler.raise(-30_000, by: 4), -30_000)
        XCTAssertLessThan(RecordingMerger.Leveler.raise(20_000, by: 1.5), RecordingMerger.Leveler.raise(25_000, by: 1.5))
    }

    func testRefusesNothingToJoin() async {
        do {
            try await RecordingMerger.merge([], into: dir.appendingPathComponent("none.mp4"))
            XCTFail("joined nothing")
        } catch {}
    }

    // MARK: Helpers

    struct Pixel: CustomStringConvertible {
        var r, g, b: Int
        /// Which of red, green and blue clearly leads. H.264 and colour management shift
        /// the exact values on the way through, but not that.
        var leadingChannel: Int? {
            let channels = [r, g, b], sorted = channels.sorted()
            return sorted[2] - sorted[1] > 60 ? channels.firstIndex(of: sorted[2]) : nil
        }
        var description: String { "rgb(\(r), \(g), \(b))" }
    }

    /// One part as SCRecordingOutput writes it: H.264 picture and AAC sound tracks in an MP4.
    /// With `reorderFrames` the picture uses B-frames and a darker bar moves across it; with
    /// `stopsJustAfterLastFrame` the part ends 1/600 s after its last frame.
    static func writePart(to url: URL, seconds: Double, color: Pixel, loud: Bool, soundTracks: Int,
                          reorderFrames: Bool = false, stopsJustAfterLastFrame: Bool = false,
                          amplitude: Double = 12_000) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let side = 64
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side]
        if reorderFrames {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAllowFrameReorderingKey: true, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 15,
            ]
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
        ])
        writer.add(video)
        let sounds = (0..<soundTracks).map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
        }
        for input in sounds {
            input.expectsMediaDataInRealTime = false
            writer.add(input)
        }
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * 30), samples = Int(seconds * 48_000), chunk = 1024
        var frame = 0
        var written = [Int](repeating: 0, count: soundTracks)
        // The writer interleaves tracks, so feed whichever input is ready until all are done.
        while frame < frames || written.contains(where: { $0 < samples }) {
            var progressed = false
            if frame < frames, video.isReadyForMoreMediaData {
                let buffer = try pixelBuffer(color, side: side, pool: adaptor.pixelBufferPool, bar: reorderFrames ? frame % side : nil)
                XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
                frame += 1
                if frame == frames { video.markAsFinished() }
                progressed = true
            }
            for (i, input) in sounds.enumerated() where written[i] < samples && input.isReadyForMoreMediaData {
                let n = min(chunk, samples - written[i])
                XCTAssertTrue(input.append(try tone(from: written[i], count: n, loud: loud, amplitude: amplitude)))
                written[i] += n
                if written[i] == samples { input.markAsFinished() }
                progressed = true
            }
            if !progressed { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        if stopsJustAfterLastFrame { writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames - 1) * 20 + 1, timescale: 600)) }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// A frame filled with `color`; with `bar`, a darker 8-pixel column starts at that x.
    static func pixelBuffer(_ color: Pixel, side: Int, pool: CVPixelBufferPool?, bar: Int? = nil) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        guard let buffer else { throw CocoaError(.featureUnsupported) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<side {
            for x in 0..<side {
                let p = base + y * row + x * 4
                let shade = bar.map { (x - $0 + side) % side < 8 } == true ? 0.6 : 1.0
                p[0] = UInt8(Double(color.b) * shade); p[1] = UInt8(Double(color.g) * shade); p[2] = UInt8(Double(color.r) * shade); p[3] = 255
            }
        }
        return buffer
    }

    /// 16-bit mono PCM at 48 kHz: a 440 Hz tone peaking at `amplitude` when `loud`, otherwise silence.
    static func tone(from start: Int, count: Int, loud: Bool, amplitude: Double = 12_000) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: count * 2,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let format, let block else { throw CocoaError(.featureUnsupported) }
        let values = (0..<count).map { i -> Int16 in
            loud ? Int16(amplitude * sin(2 * Double.pi * 440 * Double(start + i) / 48_000)) : 0
        }
        values.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000), packetDescriptions: nil,
            sampleBufferOut: &sample)
        guard let sample else { throw CocoaError(.featureUnsupported) }
        return sample
    }

    static func pixel(of asset: AVAsset, at seconds: Double) async throws -> Pixel {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Pixel(r: Int(rgba[0]), g: Int(rgba[1]), b: Int(rgba[2]))
    }

    /// Presentation and decode times of a track's samples as stored, in decode order, in seconds.
    static func sampleTimes(of asset: AVAsset, track: AVAssetTrack) throws -> [(presentation: Double, decode: Double)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [(presentation: Double, decode: Double)] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer), dts = CMSampleBufferGetDecodeTimeStamp(buffer)
            times.append((pts.seconds, dts.isValid ? dts.seconds : pts.seconds))
        }
        return times
    }

    /// Root-mean-square level of one sound track between two times, in 16-bit units.
    static func loudness(of asset: AVAsset, track: AVAssetTrack, from start: Double, to end: Double) throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                                       end: CMTime(seconds: end, preferredTimescale: 48_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var sum = 0.0, count = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var values = [Int16](repeating: 0, count: length / 2)
            values.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for v in values { sum += Double(v) * Double(v) }
            count += values.count
        }
        return count == 0 ? 0 : (sum / Double(count)).squareRoot()
    }
}
