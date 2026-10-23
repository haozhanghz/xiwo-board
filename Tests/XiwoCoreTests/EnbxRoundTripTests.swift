import CoreGraphics
import Foundation
import XCTest
@testable import XiwoCore

/// What an enbx export keeps when it is read back, and what it says it cannot keep.
final class EnbxRoundTripTests: XCTestCase {
    func testTextStyleSurvivesTheTrip() throws {
        var text = BoardElement(frame: CGRect(x: 100, y: 100, width: 420, height: 98),
                                content: .text(TextSpec(text: "  前后空格  \nUnderlined English ", fontSize: 36, color: .blue, bold: true,
                                                        underline: true, alignment: .center, background: RGBA(1, 0.95, 0.6))))
        text.opacity = 0.4
        text.growToFitText()
        let back = try roundTrip(Courseware(slides: [Slide(elements: [text])]))
        let e = back.slides[0].elements[0]
        guard case .text(let t) = e.content else { return XCTFail("not text") }
        XCTAssertEqual(t.text, "  前后空格  \nUnderlined English ")
        XCTAssertTrue(t.underline)
        XCTAssertTrue(t.bold)
        XCTAssertEqual(t.alignment, .center)
        XCTAssertEqual(t.background?.argbHex, RGBA(1, 0.95, 0.6).argbHex)
        XCTAssertEqual(e.opacity, 0.4, accuracy: 0.001)
        for (a, b) in [(e.frame.minX, text.frame.minX), (e.frame.minY, text.frame.minY),
                       (e.frame.width, text.frame.width), (e.frame.height, text.frame.height)] {
            XCTAssertEqual(a, b, accuracy: 0.001)
        }
    }

    func testPagePatternTransitionAndNameSurvive() throws {
        let tianzige = SlideBackground(color: RGBA(0.99, 0.97, 0.90), pattern: .tianzige, patternColor: RGBA(0.2, 0.6, 0.3))
        var page = Slide(name: "练习", background: tianzige, notes: "备注：田字格", transition: .fade)
        page.elements = [BoardElement(frame: CGRect(x: 10, y: 10, width: 100, height: 40), content: .text(TextSpec(text: "字")))]
        let cw = Courseware(slides: [Slide(transition: .push), page])
        let data = EnbxExporter.encode(cw)
        let back = try EnbxImporter.load(data: data).0

        XCTAssertEqual(back.slides[0].transition, .push)
        XCTAssertEqual(back.slides[1].transition, .fade)
        XCTAssertEqual(back.slides[1].name, "练习")
        XCTAssertEqual(back.slides[1].notes, "备注：田字格")
        XCTAssertEqual(back.slides[1].background.pattern, .tianzige)
        XCTAssertEqual(back.slides[1].background.patternColor.argbHex, tianzige.patternColor.argbHex)
        XCTAssertEqual(back.slides[1].background.color.argbHex, tianzige.color.argbHex)
        XCTAssertNil(back.slides[1].background.image)

        // Other readers get the pattern as a picture of the whole background.
        let zip = try ZipReader(data: data)
        let xml = try XCTUnwrap(String(data: try XCTUnwrap(try zip.read("Slides/Slide_1.xml")), encoding: .utf8))
        let source = try XCTUnwrap(xml.range(of: #"(?<=<Source>id://)[0-9a-f]+(?=</Source>)"#, options: .regularExpression))
        let png = try XCTUnwrap(try zip.read("Resources/\(xml[source])"))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertNil(try zip.read("Slides/Slide_0.xml").flatMap { String(data: $0, encoding: .utf8) }?.range(of: "ImageBrush"))
    }

    func testLinesKeepTheirDirection() throws {
        // A coordinate system's y axis: an arrow from the bottom of its box to the top.
        let style = ShapeAppearance(stroke: .black, lineWidth: 2)
        let yAxis = BoardElement(frame: CGRect(x: 640, y: 160, width: 1, height: 400),
                                 content: .shape(ShapeSpec(type: .lineArrowEnd, style: style, antiDiagonal: true)))
        let slanted = BoardElement(frame: CGRect(x: 100, y: 100, width: 300, height: 120), rotation: 30,
                                   content: .shape(ShapeSpec(type: .line, style: style, antiDiagonal: true)))
        let plain = BoardElement(frame: CGRect(x: 100, y: 400, width: 300, height: 120),
                                 content: .shape(ShapeSpec(type: .lineArrowEnd, style: style)))
        let axes = try XCTUnwrap(BoardElement.group([yAxis, slanted]))
        let back = try roundTrip(Courseware(slides: [Slide(elements: [axes, plain])]))
        guard case .group(let kids) = back.slides[0].elements[0].content else { return XCTFail("not a group") }
        for (original, read) in zip([yAxis, slanted], kids) {
            guard case .shape(let s) = read.content else { return XCTFail("not a shape") }
            XCTAssertEqual(s.antiDiagonal, true)
            XCTAssertEqual(read.rotation, original.rotation, accuracy: 0.001)
            XCTAssertEqual(read.frame, original.frame)
        }
        guard case .shape(let p) = back.slides[0].elements[1].content else { return XCTFail("not a shape") }
        XCTAssertNotEqual(p.antiDiagonal, true)
        XCTAssertEqual(back.slides[0].elements[1].rotation, 0)
    }

    /// Readers that skip the Xiwo fields still draw the line the right way round: turned
    /// by the exported rotation, its top-left-to-bottom-right line runs bottom-left to top-right.
    func testExportedRotationDrawsAntiDiagonalLinesForOtherReaders() {
        let size = CGSize(width: 300, height: 120)
        let turn = EnbxExporter.antiDiagonalTurn(size) * .pi / 180
        // Start of a top-left-to-bottom-right line, relative to the box centre, turned.
        let start = CGPoint(x: -size.width / 2, y: -size.height / 2)
        let turned = CGPoint(x: start.x * cos(turn) - start.y * sin(turn), y: start.x * sin(turn) + start.y * cos(turn))
        XCTAssertEqual(turned.x, -size.width / 2, accuracy: 1e-9)
        XCTAssertEqual(turned.y, size.height / 2, accuracy: 1e-9)   // the bottom-left corner
    }

    func testPictureOpacitySurvives() throws {
        var cw = Courseware()
        let png = try XCTUnwrap(EnbxExporter.backgroundPicture(SlideBackground(pattern: .dots), courseware: cw))
        let key = cw.addResource(data: png, name: "pic.png", ext: "png")
        var picture = BoardElement(frame: CGRect(x: 0, y: 0, width: 64, height: 36), content: .image(ImageSpec(resource: key)))
        picture.opacity = 0.7
        cw.slides[0].elements = [picture]
        XCTAssertEqual(try roundTrip(cw).slides[0].elements[0].opacity, 0.7, accuracy: 0.001)
    }

    func testExportListsWhatItCannotKeep() {
        var cw = Courseware()
        cw.slides[0].elements = [BoardElement(frame: CGRect(x: 0, y: 0, width: 100, height: 40), content: .text(TextSpec(text: "字")))]
        XCTAssertEqual(EnbxExporter.losses(in: cw), [])

        cw.slides[0].background.pattern = .tianzige
        let ink = BoardElement.stroke(points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 10, y: 10)], color: .red, width: 4, kind: .highlighter)
        let table = BoardElement(frame: CGRect(x: 0, y: 0, width: 200, height: 100), content: .table(TableSpec(rows: 2, columns: 2)))
        cw.slides[0].elements += [BoardElement.group([ink, table])!]
        XCTAssertEqual(EnbxExporter.losses(in: cw), [
            "书写格背景会存成一张背景图片",
            "笔迹会变成线条形状，之后不能再用橡皮擦除",
            "毛笔的粗细变化和荧光笔压在文字下面的效果不保留",
            "表格会变成纯文本",
        ])
    }

    private func roundTrip(_ cw: Courseware) throws -> Courseware {
        let (back, warnings) = try EnbxImporter.load(data: EnbxExporter.encode(cw))
        XCTAssertEqual(warnings, [])
        return back
    }
}
