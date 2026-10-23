import XCTest
import XiwoCore
@testable import XiwoBoard

final class DocumentEditingTests: XCTestCase {
    func testSavingCommitsTheActiveTextEditor() async throws {
        try await MainActor.run {
            let element = textElement("原文")
            let doc = DocumentModel(courseware: Courseware(slides: [Slide(elements: [element])]))
            doc.pendingTitle = "我的 新课件"
            doc.commitPendingEditing = { doc.update(element.id) { $0.content = .text(TextSpec(text: "新文字")) } }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xwb")
            defer { try? FileManager.default.removeItem(at: url) }
            try doc.save(to: url)
            let saved = try CoursewareArchive.decode(Data(contentsOf: url))
            XCTAssertEqual(text(saved.slides[0].elements[0]), "新文字")
            XCTAssertEqual(saved.title, "我的 新课件")
            XCTAssertNil(doc.pendingTitle)
            XCTAssertFalse(doc.isDirty)
            XCTAssertNil(doc.commitPendingEditing)
        }
    }

    func testSwitchingPagesCommitsTextToTheOriginalPage() async {
        await MainActor.run {
            let element = textElement("原文")
            let doc = DocumentModel(courseware: Courseware(slides: [Slide(elements: [element]), Slide()]))
            doc.commitPendingEditing = { doc.update(element.id) { $0.content = .text(TextSpec(text: "新文字")) } }
            doc.go(to: 1)
            XCTAssertEqual(doc.currentIndex, 1)
            XCTAssertEqual(text(doc.courseware.slides[0].elements[0]), "新文字")
            XCTAssertTrue(doc.slide.elements.isEmpty)
            XCTAssertNil(doc.commitPendingEditing)
        }
    }

    func testUndoAndRedoIncludePendingText() async {
        await MainActor.run {
            let element = textElement("原文")
            let doc = DocumentModel(courseware: Courseware(slides: [Slide(elements: [element])]))
            doc.commitPendingEditing = { doc.update(element.id) { $0.content = .text(TextSpec(text: "新文字")) } }
            doc.undo()
            XCTAssertEqual(text(doc.slide.elements[0]), "原文")
            XCTAssertTrue(doc.canRedo)
            doc.redo()
            XCTAssertEqual(text(doc.slide.elements[0]), "新文字")
        }
    }

    /// Ending a lecture without keeping the board writing: back to the saved document,
    /// nothing to save, and the writing can still be brought back with undo.
    func testDroppingLectureChangesLeavesNothingToSave() async throws {
        try await MainActor.run {
            let doc = DocumentModel(courseware: Courseware(slides: [Slide(elements: [textElement("原文")])]))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xwb")
            defer { try? FileManager.default.removeItem(at: url) }
            try doc.save(to: url)
            let snapshot = doc.courseware
            doc.insertText("板书", at: CGPoint(x: 10, y: 10))
            XCTAssertTrue(doc.isDirty)
            doc.restore(snapshot, unsaved: false)
            XCTAssertFalse(doc.isDirty)
            XCTAssertEqual(doc.courseware.slides, snapshot.slides)
            doc.undo()
            XCTAssertEqual(doc.slide.elements.count, 2)
            XCTAssertTrue(doc.isDirty)
        }
    }

    func testUngroupingKeepsTheGroupsTurn() async throws {
        try await MainActor.run {
            let a = BoardElement(frame: CGRect(x: 100, y: 100, width: 80, height: 40), content: .shape(ShapeSpec(type: .rectangle)))
            let b = BoardElement(frame: CGRect(x: 300, y: 200, width: 60, height: 60), content: .shape(ShapeSpec(type: .circle)))
            var group = try XCTUnwrap(BoardElement.group([a, b]))
            group.rotation = 30
            let doc = DocumentModel(courseware: Courseware(slides: [Slide(elements: [group])]))
            doc.selection = [group.id]
            doc.ungroupSelection()
            XCTAssertEqual(doc.slide.elements, group.ungrouped())
            XCTAssertEqual(doc.slide.elements.map(\.rotation), [30, 30])
            XCTAssertEqual(doc.selection, [a.id, b.id])
        }
    }

    private func textElement(_ text: String) -> BoardElement {
        BoardElement(frame: CGRect(x: 100, y: 100, width: 300, height: 80), content: .text(TextSpec(text: text)))
    }

    private func text(_ element: BoardElement) -> String? {
        guard case .text(let spec) = element.content else { return nil }
        return spec.text
    }
}
