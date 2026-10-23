import Foundation

/// Native file format (`.xwb`): a ZIP containing `courseware.json` plus each
/// resource under `resources/<hash>.<ext>`, so large media stays out of the JSON.
public enum CoursewareArchive {
    public static let fileExtension = "xwb"
    static let manifestName = "courseware.json"
    static let formatVersion = 1

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
        let zip = try ZipReader(data: data)
        guard let json = try zip.read(manifestName) else { throw ZipError.corrupt(manifestName) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: json)
        var cw = manifest.courseware
        for (key, info) in manifest.resources {
            if let d = try zip.read("resources/\(key).\(info.ext)") {
                cw.resources[key] = Resource(name: info.name, ext: info.ext, data: d)
            }
        }
        return cw
    }
}
