import CoreGraphics
import ImageIO
import XCTest
@testable import XiwoCore

final class XiwoCoreTests: XCTestCase {
    func testColorHex() {
        let c = RGBA(hex: "#80FF0000")!
        XCTAssertEqual(c.r, 1, accuracy: 0.001)
        XCTAssertEqual(c.a, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(c.argbHex, "#80FF0000")
        XCTAssertEqual(RGBA(hex: "#00FF00")!.g, 1)
        XCTAssertNil(RGBA(hex: "zz"))
    }

    func testZipRoundTrip() throws {
        var w = ZipWriter()
        let big = Data(String(repeating: "希沃白板 hello ", count: 500).utf8)
        w.add("a.txt", data: Data("hi".utf8))
        w.add("dir/大文件.xml", data: big)
        w.add("empty", data: Data())
        let r = try ZipReader(data: w.finish())
        XCTAssertEqual(r.paths, ["a.txt", "dir/大文件.xml", "empty"])
        XCTAssertEqual(try r.read("a.txt"), Data("hi".utf8))
        XCTAssertEqual(try r.read("dir\\大文件.xml"), big)
        XCTAssertEqual(try r.read("empty"), Data())
        XCTAssertEqual(r.entry("dir/大文件.xml")?.crc, CRC32.checksum(big))
    }

    func testAppVersionOrdering() throws {
        let v = try XCTUnwrap(AppVersion("v0.1.1"))
        XCTAssertEqual(v.description, "0.1.1")
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.1.0")), v)
        XCTAssertLessThan(v, try XCTUnwrap(AppVersion("0.2")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.9.9")), try XCTUnwrap(AppVersion("0.10.0")))
        XCTAssertEqual(try XCTUnwrap(AppVersion("1.0")), try XCTUnwrap(AppVersion("1.0.0")))
        XCTAssertEqual(try XCTUnwrap(AppVersion("1.2.0-beta")), try XCTUnwrap(AppVersion("1.2")))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1..2"))
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testPathParser() {
        let p = WPFPathParser.parse("M 0,0 L 100,0 100,50 H 0 Z")!
        XCTAssertEqual(p.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 100, height: 50))
        let rel = WPFPathParser.parse("m10 10 l 10 0 v 10 z")!
        XCTAssertEqual(rel.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 10, height: 10))
        let arc = WPFPathParser.parse("M0,50 A50,50 0 0 1 100,50")!
        XCTAssertEqual(arc.boundingBoxOfPath.minY, 0, accuracy: 0.5)
        let curve = WPFPathParser.parse("F1 M0,0 C 0,10 10,10 10,0 S 20,-10 20,0")
        XCTAssertNotNil(curve)
        XCTAssertNil(WPFPathParser.parse("12 34"))
    }

    func testEveryPresetShapeHasGeometry() {
        for t in ShapeType.palette {
            let p = ShapePath.path(for: t, in: CGRect(x: 10, y: 10, width: 200, height: 100))
            XCTAssertFalse(p.isEmpty, "\(t)")
            let b = p.boundingBoxOfPath
            XCTAssertGreaterThanOrEqual(b.minX, 9, "\(t)")
            XCTAssertLessThanOrEqual(b.maxX, 211, "\(t)")
        }
    }

    func testStrokeEraseSplits() {
        let pts = (0...100).map { StrokePoint(x: Double($0) * 2, y: 50) }
        let e = BoardElement.stroke(points: pts, color: .black, width: 4, kind: .pen)
        XCTAssertTrue(e.hitTest(CGPoint(x: 100, y: 52)))
        XCTAssertFalse(e.hitTest(CGPoint(x: 100, y: 80)))
        let pieces = e.erasing(center: CGPoint(x: 100, y: 50), radius: 10)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(e.erasing(center: CGPoint(x: 100, y: 300), radius: 10) == [e])
    }

    func testResizeScalesInkAndGroups() {
        var e = BoardElement.stroke(points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 100, y: 100)], color: .black, width: 2, kind: .pen)
        let f = e.frame
        e.setFrame(CGRect(x: f.minX, y: f.minY, width: f.width * 2, height: f.height * 2))
        XCTAssertEqual(e.absoluteStrokePoints.last!.x, f.minX + (100 - f.minX) * 2, accuracy: 0.01)

        let a = BoardElement(frame: CGRect(x: 0, y: 0, width: 10, height: 10), content: .shape(ShapeSpec(type: .rectangle)))
        let b = BoardElement(frame: CGRect(x: 90, y: 90, width: 10, height: 10), content: .shape(ShapeSpec(type: .circle)))
        var g = BoardElement.group([a, b])!
        XCTAssertEqual(g.frame, CGRect(x: 0, y: 0, width: 100, height: 100))
        g.setFrame(CGRect(x: 0, y: 0, width: 200, height: 200))
        guard case .group(let kids) = g.content else { return XCTFail() }
        XCTAssertEqual(kids[1].frame, CGRect(x: 180, y: 180, width: 20, height: 20))
    }

    func sampleCourseware() -> Courseware {
        var cw = Courseware(title: "测试课件")
        let png = SlideRenderer.image(of: Slide(), courseware: cw, pixelWidth: 32).flatMap(pngData)!
        let key = cw.addResource(data: png, name: "pic.png", ext: "png")
        cw.slides[0].background = SlideBackground(color: .chalkboard, pattern: .fourLines)
        cw.slides[0].elements = [
            BoardElement(frame: CGRect(x: 100, y: 100, width: 300, height: 80),
                         content: .text(TextSpec(text: "第一行\n第二行", fontSize: 40, color: .white, bold: true, alignment: .center))),
            BoardElement(frame: CGRect(x: 500, y: 100, width: 200, height: 120),
                         content: .shape(ShapeSpec(type: .star, style: ShapeAppearance(stroke: .red, fill: .yellow, lineWidth: 4)))),
            BoardElement(frame: CGRect(x: 100, y: 300, width: 64, height: 64), content: .image(ImageSpec(resource: key, name: "pic"))),
            .stroke(points: [StrokePoint(x: 10, y: 10), StrokePoint(x: 60, y: 40), StrokePoint(x: 90, y: 10)],
                    color: .blue, width: 5, kind: .pen),
        ]
        var s2 = Slide()
        s2.notes = "备注"
        s2.elements = [BoardElement(frame: CGRect(x: 0, y: 0, width: 100, height: 50), masked: true,
                                    content: .shape(ShapeSpec(type: .roundRectangle, text: "答案")))]
        cw.slides.append(s2)
        return cw
    }

    func testNativeArchiveRoundTrip() throws {
        let cw = sampleCourseware()
        let back = try CoursewareArchive.decode(CoursewareArchive.encode(cw))
        XCTAssertEqual(back.slides, cw.slides)
        XCTAssertEqual(back.resources, cw.resources)
        XCTAssertEqual(back.title, "测试课件")
    }

    func testEnbxRoundTrip() throws {
        let cw = sampleCourseware()
        let data = EnbxExporter.encode(cw)
        let paths = try ZipReader(data: data).paths
        XCTAssertTrue(paths.contains("Board.xml"))
        XCTAssertTrue(paths.contains("Slides/Slide_1.xml"))
        let (back, warnings) = try EnbxImporter.load(data: data)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(back.title, "测试课件")
        XCTAssertEqual(back.slides.map(\.id), cw.slides.map(\.id))
        XCTAssertEqual(back.slides[0].background.color.argbHex, RGBA.chalkboard.argbHex)
        let els = back.slides[0].elements
        XCTAssertEqual(els.count, 4)
        guard case .text(let t) = els[0].content else { return XCTFail("text") }
        XCTAssertEqual(t.text, "第一行\n第二行")
        XCTAssertEqual(t.fontSize, 40)
        XCTAssertTrue(t.bold)
        XCTAssertEqual(t.alignment, .center)
        guard case .shape(let s) = els[1].content else { return XCTFail("shape") }
        XCTAssertEqual(s.type, .star)
        XCTAssertEqual(s.style.fill?.argbHex, RGBA.yellow.argbHex)
        guard case .image(let img) = els[2].content else { return XCTFail("image") }
        XCTAssertNotNil(back.resources[img.resource])
        guard case .shape(let ink) = els[3].content else { return XCTFail("ink") }
        XCTAssertEqual(ink.type, .custom)
        XCTAssertTrue(back.slides[1].elements[0].masked)
        XCTAssertEqual(back.slides[1].notes, "备注")
    }

    func testRendererProducesPixelsAndPDF() {
        let cw = sampleCourseware()
        let img = SlideRenderer.image(of: cw.slides[0], courseware: cw, pixelWidth: 320)
        XCTAssertEqual(img?.width, 320)
        XCTAssertEqual(img?.height, 180)
        let pdf = SlideRenderer.pdf(of: cw)
        XCTAssertGreaterThan(pdf.count, 1000)
        XCTAssertEqual(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages, 2)
    }

    func pngData(_ img: CGImage) -> Data? {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }

    func testPenPressureFilterHoldsThroughLift() {
        var f = PenPressureFilter()
        XCTAssertEqual(f.next(0.5), 0.5, accuracy: 1e-9)
        // Near-zero samples before the pen lifts keep the last pressure.
        XCTAssertEqual(f.next(0.0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.next(0.01), 0.5, accuracy: 1e-9)
        // Real readings are smoothed, not taken raw.
        let v = f.next(1.0)
        XCTAssertGreaterThan(v, 0.5)
        XCTAssertLessThan(v, 1.0)
        // Out-of-range and non-finite input stays in 0...1.
        XCTAssertLessThanOrEqual(f.next(7), 1)
        XCTAssertLessThanOrEqual(f.next(.nan), 1)
        f.reset()
        XCTAssertEqual(f.next(0), 0.05, accuracy: 1e-9)
        XCTAssertEqual(f.next(0.3), 0.3, accuracy: 1e-9)
    }
}
