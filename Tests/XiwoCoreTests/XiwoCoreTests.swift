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

    func testChangedRegion() {
        let slide = sampleCourseware().slides[0]
        XCTAssertEqual(SlideRenderer.changedRegion(from: slide, to: slide), .null)
        var inked = slide
        inked.elements.append(.stroke(points: [StrokePoint(x: 600, y: 500), StrokePoint(x: 700, y: 560)], color: .red, width: 4, kind: .pen))
        let r = SlideRenderer.changedRegion(from: slide, to: inked)
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains(CGRect(x: 600, y: 500, width: 100, height: 60)))
        XCTAssertLessThan(r!.width, 120)
        var restacked = slide
        restacked.elements.swapAt(0, 1)
        XCTAssertNil(SlideRenderer.changedRegion(from: slide, to: restacked))
        var repainted = slide
        repainted.background.color = .white
        XCTAssertNil(SlideRenderer.changedRegion(from: slide, to: repainted))
        // Text can overflow its box downwards, so a text edit reaches the page bottom,
        // and so do mask labels.
        var retyped = slide
        retyped.elements[0].content = .text(TextSpec(text: "改了", fontSize: 40))
        XCTAssertGreaterThan(SlideRenderer.changedRegion(from: slide, to: retyped)!.maxY, 720)
        var covered = slide
        covered.elements[2].masked = true
        XCTAssertGreaterThan(SlideRenderer.changedRegion(from: slide, to: covered)!.maxY, 720)
    }

    /// Patching a render in place must give the same pixels as rendering from scratch.
    func testIncrementalRenderMatchesFullRender() throws {
        let cw = sampleCourseware()
        let old = cw.slides[0]
        var edits: [Slide] = []
        var pen = old
        pen.elements.append(.stroke(points: (0..<30).map { StrokePoint(x: 150 + Double($0) * 8, y: 120 + sin(Double($0) / 3) * 30) },
                                    color: .red, width: 6, kind: .pen))
        edits.append(pen)
        var marker = old
        marker.elements.append(.stroke(points: [StrokePoint(x: 120, y: 140), StrokePoint(x: 380, y: 150)], color: .yellow, width: 24,
                                       kind: .highlighter))
        edits.append(marker)
        var erased = old
        erased.elements.removeLast()
        edits.append(erased)
        var moved = old
        moved.elements[1].move(dx: 40, dy: 30)
        edits.append(moved)
        let base = try XCTUnwrap(SlideRenderer.image(of: old, courseware: cw, pixelWidth: 640))
        for (i, new) in edits.enumerated() {
            let patched = try XCTUnwrap(SlideRenderer.image(updating: base, from: old, to: new, courseware: cw), "edit \(i)")
            let full = try XCTUnwrap(SlideRenderer.image(of: new, courseware: cw, pixelWidth: 640))
            XCTAssertLessThanOrEqual(maxPixelDifference(patched, full), 2, "edit \(i)")
            XCTAssertGreaterThan(maxPixelDifference(patched, base), 50, "edit \(i) changed nothing")
        }
    }

    /// Live ink only redraws the tail of the stroke, so every pixel that changes when a
    /// point is added has to lie in that tail. Core Graphics re-rasterises the whole path,
    /// which can nudge a stray antialiased pixel elsewhere by one level; that is invisible.
    func testLiveStrokeTailCoversEveryChangedPixel() {
        let scale: CGFloat = 2, w = 480, h = 320
        func render(_ pts: [StrokePoint], width: Double, kind: PenKind) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            if !pts.isEmpty { SlideRenderer.drawStroke(Stroke(points: pts, color: .red, width: width, kind: kind), origin: .zero, in: ctx) }
            return data
        }
        /// Largest change to a pixel outside `tail` (bitmap row 0 is the top of the page).
        func changeOutside(_ tail: CGRect, _ a: [UInt8], _ b: [UInt8]) -> Int {
            let cols = Int(floor(tail.minX * scale))...Int(ceil(tail.maxX * scale))
            let rows = Int(floor(tail.minY * scale))...Int(ceil(tail.maxY * scale))
            var worst = 0
            for row in 0..<h {
                for col in 0..<w where !(rows.contains(row) && cols.contains(col)) {
                    let i = (row * w + col) * 4
                    for k in i..<(i + 4) where a[k] != b[k] { worst = max(worst, abs(Int(a[k]) - Int(b[k]))) }
                }
            }
            return worst
        }
        let pts = Self.wavyStroke
        for (kind, nib) in Self.inkKinds {
            let width = kind == .highlighter ? 20.0 : 8.0
            let stroke = nib ? Self.withNib(pts) : pts
            var before = render([], width: width, kind: kind)
            for n in 1...stroke.count {
                let live = Array(stroke[0..<n])
                let after = render(live, width: width, kind: kind)
                let tail = SlideRenderer.liveStrokeTail(live, width: width, kind: kind)
                // A nib's pieces are filled as one shape, and as it grows Core Graphics
                // antialiases the rest of its edge up to two levels differently.
                XCTAssertLessThanOrEqual(changeOutside(tail, before, after), nib ? 2 : 1, "\(kind)\(nib ? " with nib" : "") point \(n)")
                before = after
            }
        }
    }

    /// A wavy line with changing pressure, as a tablet writes it.
    static let wavyStroke = (0..<24).map { (i: Int) -> StrokePoint in
        let t = Double(i)
        let x: Double = 30 + t * 8 + sin(t) * 6
        let y: Double = 80 + cos(t * 0.7) * 45
        return StrokePoint(x: x, y: y, pressure: 0.3 + 0.7 * abs(sin(t * 0.9)))
    }

    /// Every pen, and the hard pen once more with a nib.
    static let inkKinds = PenKind.allCases.map { ($0, false) } + [(PenKind.pen, true)]

    /// `points` written with a nib: swelling and thinning, then narrowing to a point.
    static func withNib(_ points: [StrokePoint]) -> [StrokePoint] {
        points.enumerated().map { i, p in
            var q = p
            let end = max(0.1, min(1, Double(points.count - 1 - i) / 5))
            q.widthScale = (0.6 + 0.6 * abs(sin(Double(i) * 0.5))) * end
            return q
        }
    }

    /// The canvas keeps its page bitmap and patches it in place after every stroke or
    /// eraser pass, so after a run of edits it still has to match a full render.
    func testInPlaceUpdateMatchesFullRender() throws {
        let cw = sampleCourseware()
        var slide = cw.slides[0]
        let ctx = try XCTUnwrap(SlideRenderer.bitmap(of: slide, courseware: cw, pixelWidth: 640))
        let edits: [(String, (inout Slide) -> Void)] = [
            ("pen", { $0.elements.append(.stroke(points: (0..<30).map { StrokePoint(x: 150 + Double($0) * 8, y: 120 + sin(Double($0) / 3) * 30) },
                                                 color: .red, width: 6, kind: .pen)) }),
            ("highlighter", { $0.elements.append(.stroke(points: [StrokePoint(x: 120, y: 140), StrokePoint(x: 380, y: 150)], color: .yellow,
                                                         width: 24, kind: .highlighter)) }),
            ("erase", { $0.elements.removeLast() }),
            ("move", { $0.elements[1].move(dx: 40, dy: 30) }),
        ]
        for (name, edit) in edits {
            var next = slide
            edit(&next)
            let before = try XCTUnwrap(ctx.makeImage())
            XCTAssertTrue(SlideRenderer.update(ctx, from: slide, to: next, courseware: cw), name)
            let patched = try XCTUnwrap(ctx.makeImage())
            let full = try XCTUnwrap(SlideRenderer.image(of: next, courseware: cw, pixelWidth: 640))
            XCTAssertLessThanOrEqual(maxPixelDifference(patched, full), 2, name)
            XCTAssertGreaterThan(maxPixelDifference(patched, before), 50, "\(name) changed nothing")
            slide = next
        }
        // A new background is left to a full render, and the bitmap is not touched.
        var white = slide
        white.background = SlideBackground()
        let before = try XCTUnwrap(ctx.makeImage())
        XCTAssertFalse(SlideRenderer.update(ctx, from: slide, to: white, courseware: cw))
        XCTAssertEqual(maxPixelDifference(try XCTUnwrap(ctx.makeImage()), before), 0)
    }

    /// Live ink is drawn on the GPU from `InkTessellator`'s pieces, and the finished stroke
    /// by Core Graphics. Covering pixels the way the shader does, the pieces have to give the
    /// same line, or the ink would visibly shift or change weight when the pen lifts.
    func testInkSegmentsDrawTheSameLineAsCoreGraphics() {
        let scale = 2.0, w = 480, h = 320
        /// How much of each pixel Core Graphics covers, rows from the top of the page.
        func coreGraphics(_ stroke: Stroke) -> [Double] {
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            SlideRenderer.drawStroke(stroke, origin: .zero, in: ctx)
            // The highlighter is drawn at 40 % opacity.
            let alpha = stroke.kind == .highlighter ? 0.4 : 1
            return (0..<(w * h)).map { min(1, Double(data[$0 * 4 + 3]) / 255 / alpha) }
        }
        /// The fragment shader's coverage: a one-pixel box filter across each piece, which
        /// has round ends unless marked square, and the larger value where pieces overlap.
        func shader(_ pieces: [InkSegment]) -> [Double] {
            func band(_ t: Double, _ r: Double) -> Double { max(0, min(1, min(t + 0.5, r) - max(t - 0.5, -r))) }
            /// A nib's piece: discs of radius ra at a and rb at b joined by their tangents,
            /// covered like a line of the local radius, by distance to the edge.
            func cone(_ px: Double, _ py: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
                      _ ra: Double, _ rb: Double) -> Double {
                let len = hypot(bx - ax, by - ay)
                let r: Double, edge: Double
                if len <= abs(ra - rb) {
                    r = max(ra, rb)
                    edge = ra >= rb ? hypot(px - ax, py - ay) - r : hypot(px - bx, py - by) - r
                } else {
                    let dx = (bx - ax) / len, dy = (by - ay) / len
                    let qx = abs(-(px - ax) * dy + (py - ay) * dx), qy = (px - ax) * dx + (py - ay) * dy
                    let k = (ra - rb) / len, c = (1 - k * k).squareRoot()
                    let m = -k * qx + c * qy
                    if m < 0 {
                        r = ra; edge = hypot(qx, qy) - ra
                    } else if m > c * len {
                        r = rb; edge = hypot(qx, qy - len) - rb
                    } else {
                        r = ra + (rb - ra) * max(0, min(1, qy / len)); edge = c * qx + k * qy - ra
                    }
                }
                return band(edge + r, r)
            }
            var cover = [Double](repeating: 0, count: w * h)
            for s in pieces {
                let ax = s.a.x * scale, ay = s.a.y * scale, bx = s.b.x * scale, by = s.b.y * scale, r = s.width / 2 * scale
                let rb = s.endWidth / 2 * scale
                let len = hypot(bx - ax, by - ay)
                let (dx, dy) = len > 1e-3 ? ((bx - ax) / len, (by - ay) / len) : (1.0, 0.0)
                // Square ends reach out to their corners, r·√2 from the end point.
                let m = max(r, rb) * 1.5 + 2
                let cols = max(0, Int(min(ax, bx) - m))...min(w - 1, Int(max(ax, bx) + m))
                let rows = max(0, Int(min(ay, by) - m))...min(h - 1, Int(max(ay, by) + m))
                for row in rows {
                    for col in cols {
                        if r != rb {
                            let c = cone(Double(col) + 0.5, Double(row) + 0.5, ax, ay, bx, by, r, rb)
                            cover[row * w + col] = max(cover[row * w + col], c)
                            continue
                        }
                        let px = Double(col) + 0.5 - ax, py = Double(row) + 0.5 - ay
                        let along = px * dx + py * dy, across = abs(-px * dy + py * dx)
                        let c: Double
                        if along < 0 {
                            c = s.squareStart ? band(across, r) * max(0, min(1, r + 0.5 + along)) : band(hypot(px, py), r)
                        } else if along > len {
                            c = s.squareEnd ? band(across, r) * max(0, min(1, r + 0.5 - (along - len)))
                                            : band(hypot(Double(col) + 0.5 - bx, Double(row) + 0.5 - by), r)
                        } else {
                            c = band(across, r)
                        }
                        cover[row * w + col] = max(cover[row * w + col], c)
                    }
                }
            }
            return cover
        }
        for (kind, nib) in Self.inkKinds {
            let width = kind == .highlighter ? 20.0 : 8.0
            let pts = nib ? Self.withNib(Self.wavyStroke) : Self.wavyStroke
            // Fewer points too: a dot, a straight line and the first curve take their own paths.
            for n in [1, 2, 3, 5, pts.count] {
                let stroke = Stroke(points: Array(pts[0..<n]), color: .black, width: width, kind: kind)
                // A tenth of a pixel, as the live view asks for.
                let pieces = InkTessellator.segments(of: stroke, tolerance: 0.1 / scale)
                let a = coreGraphics(stroke), b = shader(pieces)
                var worst = 0.0, total = 0.0, inked = 0
                for i in a.indices where a[i] > 0 || b[i] > 0 {
                    worst = max(worst, abs(a[i] - b[i]))
                    total += abs(a[i] - b[i])
                    inked += 1
                }
                // Edge pixels are antialiased a little differently; nothing more. Where two
                // parts of the line nearly touch, as in the narrow turns of the wider nib line,
                // the shader keeps the larger of their coverages and Core Graphics adds them.
                XCTAssertLessThan(worst, nib ? 0.35 : 0.3, "\(kind)\(nib ? " with nib" : ""), \(n) points")
                XCTAssertLessThan(total / Double(max(1, inked)), 0.02, "\(kind)\(nib ? " with nib" : ""), \(n) points")
            }
        }
    }

    func maxPixelDifference(_ a: CGImage, _ b: CGImage) -> Int {
        func bytes(_ img: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: img.width * img.height * 4)
            let ctx = CGContext(data: &data, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return data
        }
        guard a.width == b.width, a.height == b.height else { return 255 }
        return zip(bytes(a), bytes(b)).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
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
