import AppKit
import XCTest
import XiwoCore
@testable import XiwoBoard

/// The format bar beside a selection, and the text tool handing a new box over to it.
final class FormatBarTests: XCTestCase {
    func testOutlineColourTakesItsWashWithIt() {
        var e = shape(.rectangle, stroke: .blue, fill: RGBA.blue.withAlpha(0.25))
        e.apply(.color(.red))
        XCTAssertEqual(style(e)?.stroke, .red)
        XCTAssertEqual(style(e)?.fill, RGBA.red.withAlpha(0.25))
    }

    /// A shape brought in from 希沃白板 may have a black outline round a yellow fill.
    func testAFillOfItsOwnColourStays() {
        var e = shape(.rectangle, stroke: .black, fill: RGBA.yellow.withAlpha(0.5))
        e.apply(.color(.red))
        XCTAssertEqual(style(e)?.stroke, .red)
        XCTAssertEqual(style(e)?.fill, RGBA.yellow.withAlpha(0.5))
    }

    func testFillChoices() {
        var e = shape(.circle, stroke: .green, fill: nil)
        e.apply(.fill(.solid))
        XCTAssertEqual(style(e)?.fill, .green)
        XCTAssertEqual(FormatBarState([e])?.fill, .solid)
        e.apply(.fill(.tint))
        XCTAssertEqual(style(e)?.fill, RGBA.green.withAlpha(0.25))
        XCTAssertEqual(FormatBarState([e])?.fill, .tint)
        e.apply(.fill(.none))
        XCTAssertNil(style(e)?.fill)
        // Lines and brackets are never filled.
        var line = shape(.lineArrowEnd, stroke: .black, fill: nil)
        line.apply(.fill(.solid))
        XCTAssertNil(style(line)?.fill)
    }

    func testBiggerLettersGrowTheBox() {
        var e = text("长方形有四条边，对边相等", size: 24, width: 300)
        let before = e.frame.height
        e.apply(.fontSize(72))
        XCTAssertGreaterThan(e.frame.height, before)
        XCTAssertEqual(Double(e.frame.height), e.fittedTextHeight)
        e.apply(.color(.blue))
        guard case .text(let t) = e.content else { return XCTFail("not text") }
        XCTAssertEqual(t.fontSize, 72)
        XCTAssertEqual(t.color, .blue)
    }

    func testWhatTheBarOffers() {
        let words = text("圆", size: 36, width: 200)
        let box = shape(.rectangle, stroke: .blue, fill: nil)
        let line = shape(.line, stroke: .black, fill: nil)
        let picture = BoardElement(frame: CGRect(x: 0, y: 0, width: 100, height: 100), content: .image(ImageSpec(resource: "a")))
        XCTAssertEqual(FormatBarState([line, box])?.fill, ShapeFill.none)
        XCTAssertNil(FormatBarState([line])?.fill)
        XCTAssertEqual(FormatBarState([words])?.fontSize, 36)
        XCTAssertNil(FormatBarState([words, box])?.fontSize)
        XCTAssertNil(FormatBarState([words, box])?.fill)
        XCTAssertEqual(FormatBarState([words, box])?.color, .black)
        XCTAssertNil(FormatBarState([picture]))
        XCTAssertEqual(FormatBarState([picture, box])?.color, .blue)
    }

    func testFontSizeSteps() {
        XCTAssertEqual(FormatBar.fontSize(after: 36, step: 1), 40)
        XCTAssertEqual(FormatBar.fontSize(after: 36, step: -1), 32)
        XCTAssertEqual(FormatBar.fontSize(after: 37, step: -1), 36)
        XCTAssertNil(FormatBar.fontSize(after: 200, step: 1))
        XCTAssertNil(FormatBar.fontSize(after: 12, step: -1))
    }

    func testNewShapesAndTextTakeTheLastPick() async {
        await MainActor.run {
            let tools = ToolState()
            let box = shape(.rectangle, stroke: .blue, fill: nil)
            tools.remember(.color(.red), from: [box])
            XCTAssertEqual(tools.shapeStyle.stroke, .red)
            XCTAssertEqual(tools.textSpec.color, .black)
            tools.remember(.fill(.tint), from: [box])
            XCTAssertEqual(tools.shapeStyle.fill, RGBA.red.withAlpha(0.25))
            tools.remember(.fontSize(48), from: [text("一", size: 36, width: 200)])
            XCTAssertEqual(tools.textSpec.fontSize, 48)
            XCTAssertEqual(tools.shapeStyle.stroke, .red)
        }
    }

    /// The text tool places one box, then hands over to 选择 with the box chosen and the
    /// format bar under it, so it can be moved, sized and restyled straight away.
    func testATypedTextBoxIsLeftChosen() async throws {
        try await MainActor.run {
            let metal = BoardCanvasView.metalInk
            BoardCanvasView.metalInk = false
            defer { BoardCanvasView.metalInk = metal }
            let doc = DocumentModel(courseware: Courseware(slides: [Slide()]))
            let tools = ToolState()
            tools.tool = .text
            let canvas = BoardCanvasView(document: doc, tools: tools, mode: .edit)
            // In a window, as the editor is, so the bar answers clicks.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = canvas
            canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 450)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 225), modifierFlags: [],
                                                        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            canvas.mouseDown(with: down)
            let editor = try XCTUnwrap(canvas.subviews.lazy.compactMap { $0 as? NSTextView }.first)
            XCTAssertFalse(isBarShown(in: canvas), "no bar while typing")
            editor.string = "你好"
            canvas.endEditing()
            XCTAssertEqual(tools.tool, .select)
            XCTAssertEqual(doc.slide.elements.count, 1)
            let box = doc.slide.elements[0]
            XCTAssertEqual(doc.selection, [box.id])
            guard case .text(let t) = box.content else { return XCTFail("not text") }
            XCTAssertEqual(t.text, "你好")
            XCTAssertTrue(isBarShown(in: canvas))
            let bar = try XCTUnwrap(canvas.subviews.lazy.compactMap { $0 as? FormatBarHost }.first)
            XCTAssertTrue(canvas.bounds.contains(bar.frame.insetBy(dx: FormatBar.shadowRoom, dy: FormatBar.shadowRoom)))
            XCTAssertGreaterThan(bar.frame.minY + FormatBar.shadowRoom, canvas.toView(box.frame).maxY, "under the box")
            // The margin left for the shadow lets clicks through to the page.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            bar.layoutSubtreeIfNeeded()
            XCTAssertNil(bar.hitTest(NSPoint(x: bar.frame.minX + 4, y: bar.frame.midY)))
            XCTAssertNotNil(bar.hitTest(NSPoint(x: bar.frame.midX, y: bar.frame.midY)))
            // Picking a colour there recolours the box, and the next box takes it too.
            bar.rootView.apply(.color(.red))
            guard case .text(let red) = doc.slide.elements[0].content else { return XCTFail("not text") }
            XCTAssertEqual(red.color, .red)
            XCTAssertEqual(tools.textSpec.color, .red)
            doc.undo()
            guard case .text(let undone) = doc.slide.elements[0].content else { return XCTFail("not text") }
            XCTAssertEqual(undone.color, .black)
            // Typing into it again puts the bar away.
            canvas.beginEditing(box.id)
            XCTAssertFalse(isBarShown(in: canvas))
            canvas.endEditing()
        }
    }

    @MainActor private func isBarShown(in canvas: NSView) -> Bool {
        canvas.subviews.contains { $0 is FormatBarHost && !$0.isHidden }
    }

    private func shape(_ type: ShapeType, stroke: RGBA, fill: RGBA?) -> BoardElement {
        BoardElement(frame: CGRect(x: 100, y: 100, width: 200, height: 120),
                     content: .shape(ShapeSpec(type: type, style: ShapeAppearance(stroke: stroke, fill: fill, lineWidth: 4))))
    }

    private func style(_ e: BoardElement) -> ShapeAppearance? {
        guard case .shape(let s) = e.content else { return nil }
        return s.style
    }

    private func text(_ words: String, size: Double, width: Double) -> BoardElement {
        var e = BoardElement(frame: CGRect(x: 100, y: 100, width: width, height: 0), content: .text(TextSpec(text: words, fontSize: size)))
        e.growToFitText()
        return e
    }
}
