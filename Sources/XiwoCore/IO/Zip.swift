import Compression
import Foundation

public enum ZipError: Error, LocalizedError {
    case notAZip
    case unsupportedCompression(UInt16)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "文件不是有效的压缩包"
        case .unsupportedCompression(let m): return "不支持的压缩方式 (\(m))"
        case .corrupt(let what): return "压缩包已损坏：\(what)"
        }
    }
}

/// Minimal ZIP reader: stored and deflated entries, no encryption, no ZIP64.
public struct ZipReader {
    public struct Entry {
        public let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        public let crc: UInt32
    }

    public let entries: [Entry]
    private let data: Data

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw ZipError.notAZip }
        // Find the end-of-central-directory record by scanning backwards.
        var eocd = -1
        let minStart = max(0, data.count - 65_557)
        var i = data.count - 22
        while i >= minStart {
            if data.u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = Int(data.u16(eocd + 10))
        var p = Int(data.u32(eocd + 16))
        var list: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= data.count, data.u32(p) == 0x0201_4B50 else { throw ZipError.corrupt("central directory") }
            let flags = data.u16(p + 8)
            let method = data.u16(p + 10)
            let crc = data.u32(p + 16)
            let csize = Int(data.u32(p + 20))
            let usize = Int(data.u32(p + 24))
            let nameLen = Int(data.u16(p + 28))
            let extraLen = Int(data.u16(p + 30))
            let commentLen = Int(data.u16(p + 32))
            let offset = Int(data.u32(p + 42))
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
            // Bit 11 marks UTF-8 names; older Windows tools write GBK, which is what
            // Chinese courseware archives usually contain.
            let name: String
            if flags & 0x800 != 0 {
                name = String(decoding: nameData, as: UTF8.self)
            } else {
                name = String(data: nameData, encoding: .utf8)
                    ?? String(data: nameData, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
                    ?? String(decoding: nameData, as: UTF8.self)
            }
            list.append(Entry(path: name.replacingOccurrences(of: "\\", with: "/"), method: method,
                              compressedSize: csize, uncompressedSize: usize, localHeaderOffset: offset, crc: crc))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = list
    }

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url, options: .mappedIfSafe)) }

    public var paths: [String] { entries.map(\.path) }

    public func entry(_ path: String) -> Entry? {
        let norm = path.replacingOccurrences(of: "\\", with: "/")
        return entries.first { $0.path == norm } ?? entries.first { $0.path.caseInsensitiveCompare(norm) == .orderedSame }
    }

    public func read(_ path: String) throws -> Data? {
        guard let e = entry(path) else { return nil }
        return try read(e)
    }

    public func read(_ e: Entry) throws -> Data {
        let h = e.localHeaderOffset
        guard h + 30 <= data.count, data.u32(h) == 0x0403_4B50 else { throw ZipError.corrupt("local header for \(e.path)") }
        let start = h + 30 + Int(data.u16(h + 26)) + Int(data.u16(h + 28))
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt(e.path) }
        let raw = data.subdata(in: start..<(start + e.compressedSize))
        switch e.method {
        case 0: return raw
        case 8: return try Deflate.inflate(raw, expectedSize: e.uncompressedSize)
        default: throw ZipError.unsupportedCompression(e.method)
        }
    }
}

/// Minimal ZIP writer producing deflated entries with UTF-8 names.
public struct ZipWriter {
    private var out = Data()
    private var central = Data()
    private var count = 0

    public init() {}

    public mutating func add(_ path: String, data: Data, compress: Bool = true) {
        let nameData = Data(path.utf8)
        let crc = CRC32.checksum(data)
        var body = data
        var method: UInt16 = 0
        if compress, data.count > 64, let d = try? Deflate.deflate(data), d.count < data.count {
            body = d; method = 8
        }
        let offset = UInt32(out.count)
        var local = Data()
        local.append32(0x0403_4B50)
        local.append16(20)          // version needed
        local.append16(0x800)       // UTF-8 names
        local.append16(method)
        local.append16(0); local.append16(0x21) // time/date (1980-01-01)
        local.append32(crc)
        local.append32(UInt32(body.count))
        local.append32(UInt32(data.count))
        local.append16(UInt16(nameData.count))
        local.append16(0)
        out.append(local); out.append(nameData); out.append(body)

        var c = Data()
        c.append32(0x0201_4B50)
        c.append16(0x031E)          // made by: Unix, spec 3.0
        c.append16(20)
        c.append16(0x800)
        c.append16(method)
        c.append16(0); c.append16(0x21)
        c.append32(crc)
        c.append32(UInt32(body.count))
        c.append32(UInt32(data.count))
        c.append16(UInt16(nameData.count))
        c.append16(0); c.append16(0); c.append16(0); c.append16(0)
        c.append32(0o100644 << 16)
        c.append32(offset)
        central.append(c); central.append(nameData)
        count += 1
    }

    public func finish() -> Data {
        var result = out
        let cdOffset = UInt32(result.count)
        result.append(central)
        var e = Data()
        e.append32(0x0605_4B50)
        e.append16(0); e.append16(0)
        e.append16(UInt16(count)); e.append16(UInt16(count))
        e.append32(UInt32(central.count))
        e.append32(cdOffset)
        e.append16(0)
        result.append(e)
        return result
    }
}

enum Deflate {
    static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        return try process(data, operation: COMPRESSION_STREAM_DECODE, sizeHint: expectedSize)
    }

    static func deflate(_ data: Data) throws -> Data {
        try process(data, operation: COMPRESSION_STREAM_ENCODE, sizeHint: data.count / 2 + 64)
    }

    /// COMPRESSION_ZLIB in Apple's Compression framework is raw DEFLATE (RFC 1951), which is what ZIP uses.
    private static func process(_ input: Data, operation: compression_stream_operation, sizeHint: Int) throws -> Data {
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        var status = compression_stream_init(streamPtr, operation, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else { throw ZipError.corrupt("deflate init") }
        defer { compression_stream_destroy(streamPtr) }
        let chunk = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var output = Data()
        output.reserveCapacity(sizeHint)
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            streamPtr.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
            streamPtr.pointee.src_size = input.count
            repeat {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = chunk
                status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw ZipError.corrupt("deflate stream") }
                output.append(dst, count: chunk - streamPtr.pointee.dst_size)
            } while status == COMPRESSION_STATUS_OK
        }
        return output
    }
}

extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    mutating func append16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func append32(_ v: UInt32) { append16(UInt16(v & 0xFFFF)); append16(UInt16(v >> 16)) }
}
