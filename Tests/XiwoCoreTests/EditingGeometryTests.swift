import CoreGraphics
import XCTest
@testable import XiwoCore

/// Ungrouping, text boxes that fit their text, and the eraser's sweep.
final class EditingGeometryTests: XCTestCase {
    // MARK: Ungrouping

    func testUngroupingARotatedTranslucentGroupKeepsHowItLooks() throws {
        let red = BoardElement(frame: CGRect(x: 480, y: 280, width: 160, height: 70),
                               content: .shape(ShapeSpec(type: .rectangle, style: ShapeAppearance(stroke: .red, fill: .red))))
        var blue = BoardElement(frame: CGRect(x: 700, y: 400, width: 90, height: 60),
                                content: .shape(ShapeSpec(type: .triangle, style: ShapeAppearance(stroke: .blue, fill: .blue))))
        blue.rotation = 15
        var group = try XCTUnwrap(BoardElement.group([red, blue]))
        group.rotation = 30
        group.opacity = 0.6
        group.masked = true
        group.hyperlink = "页面:2"

        let children = group.ungrouped()
        XCTAssertEqual(children.map(\.id), [red.id, blue.id])
        XCTAssertEqual(children[0].rotation, 30, accuracy: 1e-9)
        XCTAssertEqual(children[1].rotation, 45, accuracy: 1e-9)
        XCTAssertEqual(children[0].opacity, 0.6, accuracy: 1e-9)
        XCTAssertTrue(children.allSatisfy { $0.masked && $0.hyperlink == "页面:2" })
        // The red box's centre turns 30° about the group's centre.
        let c = group.center, d = CGPoint(x: red.center.x - c.x, y: red.center.y - c.y)
        let a = 30 * Double.pi / 180
        XCTAssertEqual(children[0].center.x, c.x + d.x * cos(a) - d.y * sin(a), accuracy: 1e-6)
        XCTAssertEqual(children[0].center.y, c.y + d.x * sin(a) + d.y * cos(a), accuracy: 1e-6)

        let before = try render([group]), after = try render(children)
        XCTAssertLessThan(Self.differingPixels(before, after), before.count / 4 / 500, "ungrouping changed the picture")
        // Group opacity reaches the children: nothing inside is drawn fully opaque.
        XCTAssertFalse(Self.hasOpaqueRed(before))
    }

    func testUngroupingWithoutRotationLeavesChildrenWhereTheyAre() throws {
        let a = BoardElement(frame: CGRect(x: 10, y: 10, width: 20, height: 20), content: .shape(ShapeSpec(type: .rectangle)))
        let b = BoardElement(frame: CGRect(x: 50, y: 40, width: 20, height: 20), rotation: 10, content: .shape(ShapeSpec(type: .circle)))
        let children = try XCTUnwrap(BoardElement.group([a, b])).ungrouped()
        XCTAssertEqual(children, [a, b])
    }

    // MARK: Text boxes

    func testTextBoxFollowsItsTextWhenTheStyleChanges() {
        var e = BoardElement(frame: CGRect(x: 100, y: 100, width: 420, height: 0),
                             content: .text(TextSpec(text: "改字号以后，最后一行不能跑到框外面去。Text should stay inside the box.")))
        e.growToFitText()
        let snug = e.frame.height
        XCTAssertEqual(snug, e.fittedTextHeight!, accuracy: 0.001)

        let before = e
        e.content = .text(TextSpec(text: "改字号以后，最后一行不能跑到框外面去。Text should stay inside the box.", fontSize: 44, alignment: .center))
        e.refitText(was: before)
        XCTAssertGreaterThan(e.frame.height, snug)
        XCTAssertEqual(e.frame.height, e.fittedTextHeight!, accuracy: 0.001)
        XCTAssertTrue(e.hitTest(CGPoint(x: e.frame.midX, y: e.frame.maxY - 10), tolerance: 0), "the last line can be clicked")

        // Smaller type: a box that fitted its text shrinks with it.
        let big = e
        e.content = .text(TextSpec(text: "改字号以后，最后一行不能跑到框外面去。Text should stay inside the box.", fontSize: 20))
        e.refitText(was: big)
        XCTAssertEqual(e.frame.height, e.fittedTextHeight!, accuracy: 0.001)
        XCTAssertLessThan(e.frame.height, snug)
    }

    func testTextBoxMadeTallerByHandKeepsItsRoomButStillGrows() {
        var e = BoardElement(frame: CGRect(x: 0, y: 0, width: 300, height: 400), content: .text(TextSpec(text: "标题", fontSize: 32)))
        let roomy = e
        e.content = .text(TextSpec(text: "标题", fontSize: 24))
        e.refitText(was: roomy)
        XCTAssertEqual(e.frame.height, 400)

        let before = e
        e.content = .text(TextSpec(text: String(repeating: "很长的一段文字，", count: 30), fontSize: 40))
        e.refitText(was: before)
        XCTAssertGreaterThan(e.frame.height, 400)
        XCTAssertEqual(e.frame.height, e.fittedTextHeight!, accuracy: 0.001)
    }

    func testFittedTextIsDrawnInsideItsBox() throws {
        var e = BoardElement(frame: CGRect(x: 200, y: 100, width: 420, height: 0),
                             content: .text(TextSpec(text: "第一行文字\n第二行 Second line\n第三行，比较长的一行文字会自动换行显示", fontSize: 36, underline: true)))
        e.growToFitText()
        let pixels = try render([e])
        // Rows of the page image below the box: half a slide unit per pixel.
        let firstRowBelow = Int((e.frame.maxY * 0.5).rounded(.up)) + 1
        for y in firstRowBelow..<360 {
            for x in 0..<640 where pixels[(y * 640 + x) * 4 + 1] < 200 {
                return XCTFail("text drawn below its box at (\(x), \(y))")
            }
        }
    }

    // MARK: Eraser sweep

    func testQuickEraserSweepClearsInkBetweenSamples() {
        // The sweep from the 0.1.9 review: radius 10, from (100, 150) straight to (100, 250).
        let ink = BoardElement.stroke(points: [StrokePoint(x: 0, y: 200), StrokePoint(x: 300, y: 200)], color: .blue, width: 4, kind: .pen)
        let pieces = ink.erasing(from: CGPoint(x: 100, y: 150), to: CGPoint(x: 100, y: 250), radius: 10)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].absoluteStrokePoints.last!.x, 88, accuracy: 0.001)
        XCTAssertEqual(pieces[1].absoluteStrokePoints.first!.x, 112, accuracy: 0.001)
        XCTAssertTrue(ink.hitTest(from: CGPoint(x: 100, y: 150), to: CGPoint(x: 100, y: 250), tolerance: 10))

        // Stopping short of the line touches nothing.
        XCTAssertEqual(ink.erasing(from: CGPoint(x: 100, y: 150), to: CGPoint(x: 100, y: 180), radius: 10), [ink])
        XCTAssertFalse(ink.hitTest(from: CGPoint(x: 100, y: 150), to: CGPoint(x: 100, y: 180), tolerance: 10))
    }

    func testDiagonalSweepCutsAsWideAsTheSweptBand() {
        let ink = BoardElement.stroke(points: [StrokePoint(x: 0, y: 200), StrokePoint(x: 300, y: 200)], color: .black, width: 4, kind: .pen)
        let pieces = ink.erasing(from: CGPoint(x: 50, y: 150), to: CGPoint(x: 150, y: 250), radius: 10)
        XCTAssertEqual(pieces.count, 2)
        // The band is 12 wide either side of a 45° path, so it spans 12·√2 along the ink.
        XCTAssertEqual(pieces[0].absoluteStrokePoints.last!.x, 100 - 12 * 2.0.squareRoot(), accuracy: 0.001)
        XCTAssertEqual(pieces[1].absoluteStrokePoints.first!.x, 100 + 12 * 2.0.squareRoot(), accuracy: 0.001)
    }

    func testSweepAcrossRotatedInkAndAlongTheLine() {
        var ink = BoardElement.stroke(points: [StrokePoint(x: 0, y: 50), StrokePoint(x: 200, y: 50)], color: .red, width: 4, kind: .pen)
        ink.rotation = 90   // now runs from (100, -50) down to (100, 150)
        let pieces = ink.erasing(from: CGPoint(x: 40, y: 50), to: CGPoint(x: 160, y: 50), radius: 10)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertFalse(pieces.contains { $0.hitTest(CGPoint(x: 100, y: 50), tolerance: 0) })
        XCTAssertTrue(pieces.contains { $0.hitTest(CGPoint(x: 100, y: 0), tolerance: 0) })

        // Sweeping along a whole line removes all of it.
        let line = BoardElement.stroke(points: [StrokePoint(x: 0, y: 50), StrokePoint(x: 100, y: 50)], color: .red, width: 4, kind: .pen)
        XCTAssertTrue(line.erasing(from: CGPoint(x: -20, y: 52), to: CGPoint(x: 130, y: 48), radius: 10).isEmpty)
    }

    func testSweepRevealsMaskedObjectsItCrosses() {
        let box = BoardElement(frame: CGRect(x: 100, y: 100, width: 50, height: 50), masked: true, content: .shape(ShapeSpec(type: .rectangle)))
        XCTAssertTrue(box.hitTest(from: CGPoint(x: 0, y: 120), to: CGPoint(x: 300, y: 130), tolerance: 5))
        XCTAssertFalse(box.hitTest(from: CGPoint(x: 0, y: 80), to: CGPoint(x: 300, y: 80), tolerance: 5))
    }

    // MARK: Helpers

    /// RGBA bytes of a 640×360 rendering of a white page holding `elements`.
    private func render(_ elements: [BoardElement]) throws -> [UInt8] {
        let cw = Courseware()
        let image = try XCTUnwrap(SlideRenderer.image(of: Slide(elements: elements), courseware: cw, pixelWidth: 640,
                                                      options: RenderOptions(drawMasks: false)))
        var bytes = [UInt8](repeating: 0, count: 640 * 360 * 4)
        let ctx = try XCTUnwrap(CGContext(data: &bytes, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 640, height: 360))
        return bytes
    }

    private static func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        stride(from: 0, to: a.count, by: 4).filter { i in (0..<3).contains { abs(Int(a[i + $0]) - Int(b[i + $0])) > 24 } }.count
    }

    private static func hasOpaqueRed(_ p: [UInt8]) -> Bool {
        stride(from: 0, to: p.count, by: 4).contains { p[$0] > 240 && p[$0 + 1] < 30 && p[$0 + 2] < 30 }
    }
}
