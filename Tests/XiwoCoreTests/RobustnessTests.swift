import CoreGraphics
import XCTest
@testable import XiwoCore

final class RobustnessTests: XCTestCase {
    func testSparseInkCanBeErasedBetweenItsStoredPoints() {
        let ink = BoardElement.stroke(points: [StrokePoint(x: 0, y: 50, pressure: 0.2), StrokePoint(x: 200, y: 50)],
                                      color: .red, width: 4, kind: .brush)
        let pieces = ink.erasing(center: CGPoint(x: 100, y: 50), radius: 10)
        guard pieces.count == 2 else { return XCTFail("Expected two surviving ink fragments") }
        XCTAssertEqual(pieces[0].absoluteStrokePoints.last!.x, 88, accuracy: 0.001)
        XCTAssertEqual(pieces[1].absoluteStrokePoints.first!.x, 112, accuracy: 0.001)
        XCTAssertEqual(pieces[0].absoluteStrokePoints.last!.pressure, 0.552, accuracy: 0.001)
        XCTAssertFalse(pieces.contains { $0.hitTest(CGPoint(x: 100, y: 50), tolerance: 0) })
        XCTAssertTrue(pieces.contains { $0.hitTest(CGPoint(x: 20, y: 50), tolerance: 0) })
    }

    func testErasingRotatedInkKeepsItsPositionAndProperties() {
        var ink = BoardElement.stroke(points: [StrokePoint(x: 0, y: 50), StrokePoint(x: 200, y: 50)],
                                      color: .blue, width: 4, kind: .pen)
        ink.rotation = 90
        ink.opacity = 0.6
        ink.masked = true
        ink.cloneOnDrag = true
        ink.hyperlink = "页面:2"
        let pieces = ink.erasing(center: CGPoint(x: 100, y: 50), radius: 10)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces.contains { $0.hitTest(CGPoint(x: 100, y: 10), tolerance: 0) })
        XCTAssertTrue(pieces.contains { $0.hitTest(CGPoint(x: 100, y: 90), tolerance: 0) })
        XCTAssertFalse(pieces.contains { $0.hitTest(CGPoint(x: 100, y: 50), tolerance: 0) })
        for piece in pieces {
            XCTAssertEqual(piece.rotation, 90)
            XCTAssertEqual(piece.opacity, 0.6)
            XCTAssertTrue(piece.masked)
            XCTAssertTrue(piece.cloneOnDrag)
            XCTAssertEqual(piece.hyperlink, "页面:2")
        }
        XCTAssertEqual(Set(pieces.map(\.id)).count, 2)
        XCTAssertFalse(pieces.contains { $0.id == ink.id })
    }

    func testEraserPreservesUntouchedInkAndCanEraseDots() {
        let ink = BoardElement.stroke(points: [StrokePoint(x: 0, y: 50), StrokePoint(x: 200, y: 50)],
                                      color: .black, width: 4, kind: .pen)
        XCTAssertEqual(ink.erasing(center: CGPoint(x: 100, y: 62), radius: 10), [ink])
        let dot = BoardElement.stroke(points: [StrokePoint(x: 50, y: 50)], color: .black, width: 4, kind: .pen)
        XCTAssertTrue(dot.erasing(center: CGPoint(x: 50, y: 50), radius: 10).isEmpty)
        XCTAssertEqual(dot.erasing(center: CGPoint(x: 80, y: 50), radius: 10), [dot])
    }

    func testZipRejectsTruncatedCentralDirectoryNames() throws {
        var bytes = storedZip()
        let directory = Int(bytes.u32(bytes.count - 22 + 16))
        bytes[directory + 28] = 0xFF
        bytes[directory + 29] = 0xFF
        XCTAssertThrowsError(try ZipReader(data: bytes))
    }

    func testZipRejectsCorruptedPayloadAndWrongSize() throws {
        var bytes = storedZip()
        bytes[30 + "a.txt".utf8.count] ^= 1
        let reader = try ZipReader(data: bytes)
        XCTAssertThrowsError(try reader.read("a.txt"))

        bytes = storedZip()
        let directory = Int(bytes.u32(bytes.count - 22 + 16))
        bytes[directory + 24] = 99
        let wrongSize = try ZipReader(data: bytes)
        XCTAssertThrowsError(try wrongSize.read("a.txt"))
    }

    func testZipIgnoresFalseEndRecordInsideComment() throws {
        var bytes = storedZip()
        let end = bytes.count - 22
        bytes[end + 20] = 22
        var comment = Data()
        comment.append32(0x0605_4B50)
        comment.append(Data(repeating: 0, count: 18))
        bytes.append(comment)
        let reader = try ZipReader(data: bytes)
        XCTAssertEqual(try reader.read("a.txt"), Data("hello".utf8))
    }

    func testZipRejectsEncryptedEntries() {
        var bytes = storedZip()
        let directory = Int(bytes.u32(bytes.count - 22 + 16))
        bytes[directory + 8] |= 1
        XCTAssertThrowsError(try ZipReader(data: bytes))
    }

    func testDeflateRejectsUnexpectedOutputSizeAndTruncation() throws {
        let input = Data(String(repeating: "a", count: 1000).utf8)
        let compressed = try Deflate.deflate(input)
        XCTAssertThrowsError(try Deflate.inflate(compressed, expectedSize: 10))
        XCTAssertThrowsError(try Deflate.inflate(compressed, expectedSize: 1001))
        XCTAssertThrowsError(try Deflate.inflate(Data(compressed.prefix(2)), expectedSize: input.count))
        XCTAssertThrowsError(try Deflate.inflate(Data(), expectedSize: input.count))
    }

    func testArchiveRejectsFutureFormatsEmptySlidesAndInvalidSizes() throws {
        XCTAssertThrowsError(try CoursewareArchive.decode(archive(Courseware(), format: 999)))
        var cw = Courseware()
        cw.slides = []
        XCTAssertThrowsError(try CoursewareArchive.decode(archive(cw)))
        cw = Courseware(slideSize: CGSize(width: 0, height: 720))
        XCTAssertThrowsError(try CoursewareArchive.decode(archive(cw)))
        cw.slideSize = CGSize(width: 1280, height: -1)
        XCTAssertThrowsError(try CoursewareArchive.decode(archive(cw)))
    }

    func testArchiveRejectsMalformedTablesInsideGroups() throws {
        var table = TableSpec(rows: 2, columns: 2)
        table.cells = [["only one cell"]]
        let child = BoardElement(frame: CGRect(x: 0, y: 0, width: 100, height: 100), content: .table(table))
        let group = BoardElement(frame: child.frame, content: .group([child]))
        let cw = Courseware(slides: [Slide(elements: [group])])
        XCTAssertThrowsError(try CoursewareArchive.decode(archive(cw)))
    }

    func testArchiveReportsMissingResourceFiles() throws {
        var cw = Courseware()
        cw.addResource(data: Data("image".utf8), name: "missing.png", ext: "png")
        XCTAssertThrowsError(try CoursewareArchive.decode(archive(cw))) { error in
            guard case CoursewareArchive.ArchiveError.missingResource("missing.png") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCaptureDimensionsFitLandscapePortraitAndUltrawideScreens() {
        let landscape = CaptureSize(width: 6016, height: 3384)
        XCTAssertEqual(landscape.width, 3840)
        XCTAssertEqual(landscape.height, 2160)
        let portrait = CaptureSize(width: 2160, height: 3840)
        XCTAssertEqual(portrait.width, 1214)
        XCTAssertEqual(portrait.height, 2160)
        let wide = CaptureSize(width: 5120, height: 1440)
        XCTAssertEqual(wide.width, 3840)
        XCTAssertEqual(wide.height, 1080)
        let odd = CaptureSize(width: 1919, height: 1079)
        XCTAssertEqual(odd.width, 1918)
        XCTAssertEqual(odd.height, 1078)
        XCTAssertEqual(CaptureSize(width: .infinity, height: 0), CaptureSize(width: 2, height: 2))
    }

    func testRendererRejectsInvalidDimensions() {
        let cw = Courseware(slideSize: CGSize(width: 0, height: 720))
        XCTAssertNil(SlideRenderer.image(of: Slide(), courseware: cw, pixelWidth: 320))
        XCTAssertNil(SlideRenderer.image(of: Slide(), courseware: Courseware(), pixelWidth: 0))
    }

    private func storedZip() -> Data {
        var writer = ZipWriter()
        writer.add("a.txt", data: Data("hello".utf8), compress: false)
        return writer.finish()
    }

    private func archive(_ courseware: Courseware, format: Int = 1) throws -> Data {
        var cw = courseware
        let infos = cw.resources.mapValues { CoursewareArchive.ResourceInfo(name: $0.name, ext: $0.ext) }
        cw.resources = [:]
        let manifest = CoursewareArchive.Manifest(format: format, app: "XiwoBoard", courseware: cw, resources: infos)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var writer = ZipWriter()
        writer.add("courseware.json", data: try encoder.encode(manifest))
        return writer.finish()
    }
}
