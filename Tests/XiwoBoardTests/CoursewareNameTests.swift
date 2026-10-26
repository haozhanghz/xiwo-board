import XCTest
import XiwoCore
@testable import XiwoBoard

/// A saved courseware is called what its file is called, so the home page and the editor agree.
final class CoursewareNameTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Courseware saved before names followed files still says 未命名课件 inside.
    func testOpeningTakesTheFileName() async throws {
        try await MainActor.run {
            let url = folder.appendingPathComponent("一年级数学.xwb")
            try CoursewareArchive.encode(Courseware()).write(to: url)
            let (doc, _) = try DocumentModel.open(url: url)
            XCTAssertEqual(doc.title, "一年级数学")
            XCTAssertFalse(doc.isDirty)
        }
    }

    func testRenamingASavedCoursewareRenamesItsFile() async throws {
        try await MainActor.run {
            let doc = try savedDocument(named: "甲")
            let old = try XCTUnwrap(doc.fileURL)
            doc.rename("乙")
            let new = folder.appendingPathComponent("乙.xwb")
            XCTAssertEqual(doc.title, "乙")
            XCTAssertEqual(doc.fileURL?.path, new.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
            XCTAssertTrue(RecentFiles.urls.contains { $0.path == new.path })
            XCTAssertFalse(RecentFiles.urls.contains { $0.path == old.path })
            XCTAssertEqual(try DocumentModel.open(url: new).0.title, "乙")
            RecentFiles.remove(new)
        }
    }

    /// Undoing the writing that came before a rename leaves the name, which the file carries.
    func testUndoKeepsTheName() async throws {
        try await MainActor.run {
            let doc = try savedDocument(named: "甲")
            doc.insertText("板书", at: CGPoint(x: 10, y: 10))
            doc.rename("乙")
            doc.undo()
            XCTAssertTrue(doc.slide.elements.isEmpty)
            XCTAssertEqual(doc.title, "乙")
            doc.redo()
            XCTAssertEqual(doc.title, "乙")
            RecentFiles.remove(folder.appendingPathComponent("乙.xwb"))
        }
    }

    /// Finder shows a ":" in a file name as "/", so a "/" in the name is kept.
    func testSlashInTheNameSurvivesTheFile() async throws {
        try await MainActor.run {
            let doc = try savedDocument(named: "甲")
            doc.rename("3/4 分数")
            let url = try XCTUnwrap(doc.fileURL)
            XCTAssertEqual(url.lastPathComponent, "3:4 分数.xwb")
            XCTAssertEqual(try DocumentModel.open(url: url).0.title, "3/4 分数")
            RecentFiles.remove(url)
        }
    }

    func testRenamingOntoAnotherCoursewareKeepsTheOldName() async throws {
        try await MainActor.run {
            let doc = try savedDocument(named: "甲")
            let other = folder.appendingPathComponent("乙.xwb")
            try Data("other".utf8).write(to: other)
            var reported: Error?
            let report = DocumentModel.reportError
            DocumentModel.reportError = { reported = $0 }
            defer { DocumentModel.reportError = report }
            doc.rename("乙")
            XCTAssertNotNil(reported)
            XCTAssertEqual(doc.title, "甲")
            XCTAssertEqual(doc.fileURL?.lastPathComponent, "甲.xwb")
            XCTAssertEqual(try Data(contentsOf: other), Data("other".utf8))
            RecentFiles.remove(folder.appendingPathComponent("甲.xwb"))
        }
    }

    /// Saved the way 保存 does it: named after the file chosen in the save panel.
    @MainActor private func savedDocument(named name: String) throws -> DocumentModel {
        let doc = DocumentModel()
        let url = folder.appendingPathComponent(name + ".xwb")
        doc.takeName(from: url)
        try doc.save(to: url)
        XCTAssertEqual(doc.title, name)
        return doc
    }
}
