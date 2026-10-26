import AppKit
import ImageIO
import UniformTypeIdentifiers
import XiwoCore

/// Save/open panels and export helpers.
@MainActor
enum Exporter {
    static func pngData(_ img: CGImage) -> Data? {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }

    static func savePNG(_ img: CGImage, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName + ".png"
        guard panel.runModal() == .OK, let url = panel.url, let data = pngData(img) else { return }
        try? data.write(to: url)
    }

    static func exportPDF(_ doc: DocumentModel) {
        doc.finishEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = doc.title + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try SlideRenderer.pdf(of: doc.courseware).write(to: url) } catch { showError(error) }
    }

    /// Exports every page as numbered PNGs into a chosen folder.
    static func exportImages(_ doc: DocumentModel) {
        doc.finishEditing()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到此处"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for (i, s) in doc.courseware.slides.enumerated() {
            guard let img = SlideRenderer.image(of: s, courseware: doc.courseware, pixelWidth: 1920,
                                                options: RenderOptions(drawMasks: false)),
                  let data = pngData(img) else { continue }
            try? data.write(to: dir.appendingPathComponent("\(doc.title.coursewareFileName)-\(i + 1).png"))
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    static func exportEnbx(_ doc: DocumentModel) {
        doc.finishEditing()
        let losses = EnbxExporter.losses(in: doc.courseware)
        if !losses.isEmpty {
            let a = NSAlert()
            a.messageText = "导出为 .enbx 会改变部分内容"
            a.informativeText = losses.map { "• " + $0 }.joined(separator: "\n") + "\n\n完整的课件请继续保存为 .xwb。"
            a.addButton(withTitle: "继续导出")
            a.addButton(withTitle: "取消")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.enbx]
        panel.nameFieldStringValue = doc.title + ".enbx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try doc.save(to: url) } catch { showError(error) }
    }

    /// Returns false if the user cancelled.
    @discardableResult
    static func save(_ doc: DocumentModel, forceChoose: Bool = false) -> Bool {
        doc.finishEditing()
        var url = doc.fileURL
        if url == nil || forceChoose {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.xiwoBoard]
            panel.nameFieldStringValue = doc.title + "." + CoursewareArchive.fileExtension
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            // Saved under a new name, the courseware takes it, as the home page will show it.
            doc.takeName(from: chosen)
            url = chosen
        }
        guard let url else { return false }
        do { try doc.save(to: url); return true } catch { showError(error); return false }
    }

    static func chooseCourseware() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xiwoBoard, .enbx]
        panel.allowsOtherFileTypes = true
        panel.message = "选择课件（.xwb 或 .enbx）"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFiles(_ types: [UTType], multiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func showError(_ error: Error) {
        let a = NSAlert(error: error)
        a.runModal()
    }

    static func insertImages(into doc: DocumentModel) {
        for url in chooseFiles([.image]) { insertImage(url, into: doc) }
    }

    static func insertImage(_ url: URL, into doc: DocumentModel) {
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return }
        let w = props[kCGImagePropertyPixelWidth] as? Double ?? 400
        let h = props[kCGImagePropertyPixelHeight] as? Double ?? 300
        doc.insertImage(data: data, name: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension,
                        pixelSize: CGSize(width: w, height: h))
    }

    static func insertMedia(into doc: DocumentModel) {
        for url in chooseFiles([.movie, .audio]) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let isVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
            doc.insertMedia(data: data, name: url.lastPathComponent, ext: url.pathExtension, kind: isVideo ? .video : .audio)
        }
    }
}
