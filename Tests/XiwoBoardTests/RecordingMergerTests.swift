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
    static func writePart(to url: URL, seconds: Double, color: Pixel, loud: Bool, soundTracks: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let side = 64
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
        ])
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
                let buffer = try pixelBuffer(color, side: side, pool: adaptor.pixelBufferPool)
                XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
                frame += 1
                if frame == frames { video.markAsFinished() }
                progressed = true
            }
            for (i, input) in sounds.enumerated() where written[i] < samples && input.isReadyForMoreMediaData {
                let n = min(chunk, samples - written[i])
                XCTAssertTrue(input.append(try tone(from: written[i], count: n, loud: loud)))
                written[i] += n
                if written[i] == samples { input.markAsFinished() }
                progressed = true
            }
            if !progressed { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func pixelBuffer(_ color: Pixel, side: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
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
                p[0] = UInt8(color.b); p[1] = UInt8(color.g); p[2] = UInt8(color.r); p[3] = 255
            }
        }
        return buffer
    }

    /// 16-bit mono PCM at 48 kHz: a 440 Hz tone when `loud`, otherwise silence.
    static func tone(from start: Int, count: Int, loud: Bool) throws -> CMSampleBuffer {
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
            loud ? Int16(12_000 * sin(2 * Double.pi * 440 * Double(start + i) / 48_000)) : 0
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
