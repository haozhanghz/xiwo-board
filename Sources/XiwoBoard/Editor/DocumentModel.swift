import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import XiwoCore

/// One open courseware plus its editing state (current page, selection, undo).
@MainActor
final class DocumentModel: ObservableObject {
    @Published private(set) var courseware: Courseware
    @Published var currentIndex: Int = 0 {
        didSet {
            if currentIndex != oldValue { selection = []; MediaPlayerOverlay.stop() }
        }
    }
    @Published var selection: Set<String> = []
    @Published private(set) var isDirty = false
    @Published var fileURL: URL?
    /// Bumps on every content change so views holding caches can refresh.
    @Published private(set) var revision = 0
    @Published var pendingTitle: String?
    /// The canvas installs this only while an in-place text editor is active.
    var commitPendingEditing: (() -> Void)?

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private struct Snapshot { var courseware: Courseware; var index: Int }

    init(courseware: Courseware = Courseware(), fileURL: URL? = nil) {
        self.courseware = courseware
        self.fileURL = fileURL
    }

    var title: String { courseware.title }
    var slide: Slide { courseware.slides[min(currentIndex, courseware.slides.count - 1)] }
    var slideCount: Int { courseware.slides.count }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var selectedElements: [BoardElement] { slide.elements.filter { selection.contains($0.id) } }

    // MARK: Mutation & undo

    func finishEditing() {
        let title = pendingTitle
        if title != nil { pendingTitle = nil }
        let commit = commitPendingEditing
        commitPendingEditing = nil
        commit?()
        if let title { rename(title) }
    }

    /// Records an undo point, then applies `change` to the whole document.
    func edit(_ change: (inout Courseware) -> Void) {
        finishEditing()
        pushUndo()
        change(&courseware)
        didChange()
    }

    /// Applies `change` to the current slide with an undo point.
    func editSlide(_ change: (inout Slide) -> Void) {
        let i = currentIndex
        edit { change(&$0.slides[i]) }
    }

    /// Applies a change without an undo point; pair with `beginGesture()` for drags.
    func editSlideLive(_ change: (inout Slide) -> Void) {
        change(&courseware.slides[currentIndex])
        didChange()
    }

    /// Records the undo point for a continuous gesture (drag, erase) before it begins.
    func beginGesture() { pushUndo() }

    private func pushUndo() {
        undoStack.append(Snapshot(courseware: courseware, index: currentIndex))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func didChange() {
        courseware.modified = Date()
        isDirty = true
        revision &+= 1
        let ids = Set(slide.elements.map(\.id))
        selection = selection.intersection(ids)
    }

    func undo() {
        finishEditing()
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(courseware: courseware, index: currentIndex))
        courseware = s.courseware
        currentIndex = min(s.index, courseware.slides.count - 1)
        didChange()
    }

    func redo() {
        finishEditing()
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(courseware: courseware, index: currentIndex))
        courseware = s.courseware
        currentIndex = min(s.index, courseware.slides.count - 1)
        didChange()
    }

    func rename(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != courseware.title else { return }
        edit { $0.title = t }
    }

    // MARK: Pages

    func addSlide(after index: Int? = nil, background: SlideBackground? = nil) {
        let at = (index ?? currentIndex) + 1
        edit { cw in
            let bg = background ?? cw.slides[min(at - 1, cw.slides.count - 1)].background
            cw.slides.insert(Slide(background: SlideBackground(color: bg.color, pattern: bg.pattern, patternColor: bg.patternColor)), at: at)
        }
        currentIndex = at
    }

    func duplicateSlide(at index: Int) {
        edit { $0.slides.insert($0.slides[index].duplicated(), at: index + 1) }
        currentIndex = index + 1
    }

    func deleteSlide(at index: Int) {
        guard courseware.slides.count > 1 else {
            edit { $0.slides[0] = Slide(background: $0.slides[0].background) }
            return
        }
        edit { _ = $0.slides.remove(at: index) }
        currentIndex = min(currentIndex, courseware.slides.count - 1)
    }

    func moveSlide(from source: IndexSet, to destination: Int) {
        let currentID = slide.id
        edit { $0.slides.move(fromOffsets: source, toOffset: destination) }
        currentIndex = courseware.slides.firstIndex { $0.id == currentID } ?? 0
    }

    func go(to index: Int) {
        finishEditing()
        currentIndex = max(0, min(courseware.slides.count - 1, index))
    }

    // MARK: Elements

    func insert(_ element: BoardElement, select: Bool = true) {
        editSlide { $0.elements.append(element) }
        if select { selection = [element.id] }
    }

    func update(_ id: String, _ change: (inout BoardElement) -> Void) {
        editSlide { s in
            if let i = s.elements.firstIndex(where: { $0.id == id }) { change(&s.elements[i]) }
        }
    }

    func updateSelected(_ change: (inout BoardElement) -> Void) {
        let ids = selection
        guard !ids.isEmpty else { return }
        editSlide { s in
            for i in s.elements.indices where ids.contains(s.elements[i].id) { change(&s.elements[i]) }
        }
    }

    func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        editSlide { $0.elements.removeAll { ids.contains($0.id) && !$0.locked } }
    }

    func selectAll() { selection = Set(slide.elements.filter { !$0.locked }.map(\.id)) }

    func clearInk() {
        guard slide.elements.contains(where: \.isStroke) else { return }
        editSlide { $0.elements.removeAll(where: \.isStroke) }
    }

    enum Arrange { case front, back, forward, backward }

    func arrange(_ how: Arrange) {
        let ids = selection
        guard !ids.isEmpty else { return }
        editSlide { s in
            let picked = s.elements.filter { ids.contains($0.id) }
            switch how {
            case .front:
                s.elements.removeAll { ids.contains($0.id) }
                s.elements.append(contentsOf: picked)
            case .back:
                s.elements.removeAll { ids.contains($0.id) }
                s.elements.insert(contentsOf: picked, at: 0)
            case .forward:
                for i in stride(from: s.elements.count - 2, through: 0, by: -1) where ids.contains(s.elements[i].id) && !ids.contains(s.elements[i + 1].id) {
                    s.elements.swapAt(i, i + 1)
                }
            case .backward:
                for i in 1..<max(1, s.elements.count) where ids.contains(s.elements[i].id) && !ids.contains(s.elements[i - 1].id) {
                    s.elements.swapAt(i, i - 1)
                }
            }
        }
    }

    func groupSelection() {
        let ids = selection
        let picked = slide.elements.filter { ids.contains($0.id) }
        guard let g = BoardElement.group(picked) else { return }
        editSlide { s in
            let at = s.elements.firstIndex { ids.contains($0.id) } ?? s.elements.count
            s.elements.removeAll { ids.contains($0.id) }
            s.elements.insert(g, at: min(at, s.elements.count))
        }
        selection = [g.id]
    }

    func ungroupSelection() {
        var newSel: Set<String> = []
        let ids = selection
        editSlide { s in
            var out: [BoardElement] = []
            for e in s.elements {
                if ids.contains(e.id), case .group(let kids) = e.content {
                    out.append(contentsOf: kids); kids.forEach { newSel.insert($0.id) }
                } else { out.append(e) }
            }
            s.elements = out
        }
        selection = newSel
    }

    enum Alignment { case left, hCenter, right, top, vCenter, bottom }

    func align(_ how: Alignment) {
        let els = selectedElements
        guard let bounds = els.count > 1 ? BoardElement.union(els) : CGRect(origin: .zero, size: courseware.slideSize) else { return }
        updateSelected { e in
            let b = e.boundingBox
            switch how {
            case .left: e.move(dx: bounds.minX - b.minX, dy: 0)
            case .hCenter: e.move(dx: bounds.midX - b.midX, dy: 0)
            case .right: e.move(dx: bounds.maxX - b.maxX, dy: 0)
            case .top: e.move(dx: 0, dy: bounds.minY - b.minY)
            case .vCenter: e.move(dx: 0, dy: bounds.midY - b.midY)
            case .bottom: e.move(dx: 0, dy: bounds.maxY - b.maxY)
            }
        }
    }

    // MARK: Clipboard

    static let pasteboardType = NSPasteboard.PasteboardType("com.xiwoboard.elements")

    private struct ClipPayload: Codable { var elements: [BoardElement]; var resources: [String: Resource] }

    func copySelection() {
        finishEditing()
        let els = selectedElements
        guard !els.isEmpty else { return }
        var res: [String: Resource] = [:]
        func collect(_ e: BoardElement) {
            switch e.content {
            case .image(let i): res[i.resource] = courseware.resources[i.resource]
            case .media(let m): res[m.resource] = courseware.resources[m.resource]
            case .group(let g): g.forEach(collect)
            default: break
            }
        }
        els.forEach(collect)
        guard let data = try? JSONEncoder().encode(ClipPayload(elements: els, resources: res)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        if let img = SlideRenderer.image(of: Slide(background: SlideBackground(color: .clear), elements: els),
                                          courseware: courseware, pixelWidth: 1280) {
            pb.writeObjects([NSImage(cgImage: img, size: .zero)])
        }
    }

    func cut() { copySelection(); deleteSelection() }

    func paste() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.pasteboardType),
           let payload = try? JSONDecoder().decode(ClipPayload.self, from: data) {
            let copies = payload.elements.map { $0.duplicated(dx: 20, dy: 20) }
            edit { cw in
                for (k, r) in payload.resources where cw.resources[k] == nil { cw.resources[k] = r }
                cw.slides[currentIndex].elements.append(contentsOf: copies)
            }
            selection = Set(copies.map(\.id))
        } else if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            insertImage(data: png, name: "粘贴的图片", ext: "png", pixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        } else if let s = pb.string(forType: .string), !s.isEmpty {
            insertText(s, at: CGPoint(x: 200, y: 200))
        }
    }

    func duplicateSelection() { copySelection(); paste() }

    // MARK: Inserting content

    func insertText(_ text: String = "", at p: CGPoint, spec: TextSpec? = nil) {
        var t = spec ?? TextSpec(text: text)
        t.text = text
        let width = 420.0
        let h = SlideRenderer.textHeight(t, width: width - 12) + 8
        insert(BoardElement(frame: CGRect(x: p.x, y: p.y, width: width, height: h), content: .text(t)))
    }

    func insertImage(data: Data, name: String, ext: String, pixelSize: CGSize) {
        var key = ""
        let size = courseware.slideSize
        let scale = min(1, min(size.width * 0.6 / max(pixelSize.width, 1), size.height * 0.6 / max(pixelSize.height, 1)))
        let w = pixelSize.width * scale, h = pixelSize.height * scale
        let el = BoardElement(frame: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h),
                              content: .image(ImageSpec(resource: "", name: name)))
        var element = el
        edit { cw in
            key = cw.addResource(data: data, name: name, ext: ext)
            element.content = .image(ImageSpec(resource: key, name: name))
            cw.slides[currentIndex].elements.append(element)
        }
        selection = [element.id]
    }

    func insertMedia(data: Data, name: String, ext: String, kind: MediaKind) {
        let size = courseware.slideSize
        let w: Double = kind == .video ? 480 : 220, h: Double = kind == .video ? 270 : 140
        var element = BoardElement(frame: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h),
                                   content: .group([]))
        edit { cw in
            let key = cw.addResource(data: data, name: name, ext: ext)
            element.content = .media(MediaSpec(kind: kind, resource: key, name: name))
            cw.slides[currentIndex].elements.append(element)
        }
        selection = [element.id]
    }

    func insertTable(rows: Int, columns: Int) {
        let w = Double(columns) * 140, h = Double(rows) * 54
        let size = courseware.slideSize
        insert(BoardElement(frame: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h),
                            content: .table(TableSpec(rows: rows, columns: columns))))
    }

    func insertShape(_ type: ShapeType, style: ShapeAppearance) {
        let size = courseware.slideSize
        let w: CGFloat = 240, h: CGFloat = type.isLine ? 0 : 160
        insert(BoardElement(frame: CGRect(x: (size.width - w) / 2, y: (size.height - max(h, 1)) / 2, width: w, height: max(h, 1)),
                            content: .shape(ShapeSpec(type: type, style: style))))
    }

    // MARK: Files

    func save(to url: URL) throws {
        finishEditing()
        let data: Data
        switch url.pathExtension.lowercased() {
        case "enbx": data = EnbxExporter.encode(courseware)
        default: data = try CoursewareArchive.encode(courseware)
        }
        try data.write(to: url, options: .atomic)
        if url.pathExtension.lowercased() == CoursewareArchive.fileExtension {
            fileURL = url
            isDirty = false
        }
        RecentFiles.add(url)
    }

    static func open(url: URL) throws -> (DocumentModel, [String]) {
        switch url.pathExtension.lowercased() {
        case "enbx":
            let (cw, warnings) = try EnbxImporter.load(url: url)
            RecentFiles.add(url)
            return (DocumentModel(courseware: cw), warnings)
        default:
            let (cw, missing) = try CoursewareArchive.load(Data(contentsOf: url))
            RecentFiles.add(url)
            return (DocumentModel(courseware: cw, fileURL: url), missing.map { "资源缺失：\($0)" })
        }
    }
}

/// Recently opened courseware, newest first.
enum RecentFiles {
    private static let key = "recentFiles"

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(20)), forKey: key)
    }

    static func remove(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        UserDefaults.standard.set(list, forKey: key)
    }
}

extension UTType {
    static let xiwoBoard = UTType(filenameExtension: CoursewareArchive.fileExtension, conformingTo: .data) ?? .data
    static let enbx = UTType(filenameExtension: "enbx") ?? .data
}
