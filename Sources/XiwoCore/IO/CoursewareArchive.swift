import Foundation

/// Native file format (`.xwb`): a ZIP containing `courseware.json` plus each
/// resource under `resources/<hash>.<ext>`, so large media stays out of the JSON.
public enum CoursewareArchive {
    public static let fileExtension = "xwb"
    static let manifestName = "courseware.json"
    static let formatVersion = 1

    public enum ArchiveError: LocalizedError {
        case unsupportedVersion(Int)
        case invalidDocument

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): return "课件格式版本（\(version)）暂不支持，请更新「录课」。"
            case .invalidDocument: return "课件内容无效：请检查页面、尺寸或表格数据。"
            }
        }
    }

    struct Manifest: Codable {
        var format: Int
        var app: String
        var courseware: Courseware
        var resources: [String: ResourceInfo]
    }

    struct ResourceInfo: Codable {
        var name: String
        var ext: String
    }

    public static func encode(_ courseware: Courseware) throws -> Data {
        var cw = courseware
        cw.pruneResources()
        let resources = cw.resources
        cw.resources = [:]
        let manifest = Manifest(format: formatVersion, app: "XiwoBoard", courseware: cw,
                                resources: resources.mapValues { ResourceInfo(name: $0.name, ext: $0.ext) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var zip = ZipWriter()
        zip.add(manifestName, data: try encoder.encode(manifest))
        for (key, r) in resources.sorted(by: { $0.key < $1.key }) {
            // Already-compressed media gains nothing from deflate.
            let compress = !["png", "jpg", "jpeg", "gif", "heic", "mp4", "mov", "m4a", "mp3", "webp"].contains(r.ext)
            zip.add("resources/\(key).\(r.ext)", data: r.data, compress: compress)
        }
        return zip.finish()
    }

    public static func decode(_ data: Data) throws -> Courseware {
        try load(data).courseware
    }

    /// Decodes the archive and names the resources that are missing or damaged in it.
    /// Those are left out, so the rest of the courseware still opens; the elements
    /// that used them draw a placeholder.
    public static func load(_ data: Data) throws -> (courseware: Courseware, missing: [String]) {
        let zip = try ZipReader(data: data)
        guard let json = try zip.read(manifestName) else { throw ZipError.corrupt(manifestName) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: json)
        guard manifest.format == formatVersion else { throw ArchiveError.unsupportedVersion(manifest.format) }
        var cw = manifest.courseware
        guard !cw.slides.isEmpty, cw.slideSize.width.isFinite, cw.slideSize.height.isFinite,
              cw.slideSize.width > 0, cw.slideSize.height > 0,
              cw.slides.allSatisfy({ $0.elements.allSatisfy(validElement) }) else { throw ArchiveError.invalidDocument }
        var missing: [String] = []
        for (key, info) in manifest.resources.sorted(by: { $0.key < $1.key }) {
            guard let d = try? zip.read("resources/\(key).\(info.ext)") else { missing.append(info.name); continue }
            cw.resources[key] = Resource(name: info.name, ext: info.ext, data: d)
        }
        return (cw, missing)
    }

    private static func validElement(_ element: BoardElement) -> Bool {
        let f = element.frame
        guard [f.origin.x, f.origin.y, f.width, f.height].allSatisfy(\.isFinite),
              element.rotation.isFinite, element.opacity.isFinite,
              f.width >= 0, f.height >= 0 else { return false }
        switch element.content {
        case .table(let t):
            return t.rows > 0 && t.columns > 0 && t.cells.count == t.rows && t.cells.allSatisfy { $0.count == t.columns }
        case .group(let children): return children.allSatisfy(validElement)
        default: return true
        }
    }
}
