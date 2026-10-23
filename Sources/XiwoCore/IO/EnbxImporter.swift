import CoreGraphics
import Foundation

/// Best-effort reader for `.enbx` courseware.
///
/// Layout (observed for interoperability): a ZIP holding `Document.xml`
/// (metadata), `Board.xml` (slide order and theme), `Reference.xml`
/// (resource relationships), `Slides/*.xml` (one per page) and
/// `Resources/<md5>` blobs. Each XML element stores its fields as child
/// elements, and polymorphic values are wrapped in an element named after
/// their type, e.g. `<Background><ColorBrush>#FFFFFFFF</ColorBrush></Background>`.
///
/// Element kinds we do not model are skipped and reported in `warnings`.
public struct EnbxImporter {
    public private(set) var warnings: [String] = []
    private let zip: ZipReader
    private var references: [String: String] = [:]   // id -> zip path
    private var courseware = Courseware()
    private var resourceKeys: [String: String] = [:]  // zip path -> resource key

    public static func load(url: URL) throws -> (Courseware, [String]) {
        var importer = try EnbxImporter(zip: ZipReader(url: url))
        let cw = try importer.run(fallbackTitle: url.deletingPathExtension().lastPathComponent)
        return (cw, importer.warnings)
    }

    public static func load(data: Data, title: String = "导入的课件") throws -> (Courseware, [String]) {
        var importer = try EnbxImporter(zip: ZipReader(data: data))
        let cw = try importer.run(fallbackTitle: title)
        return (cw, importer.warnings)
    }

    init(zip: ZipReader) { self.zip = zip }

    mutating func run(fallbackTitle: String) throws -> Courseware {
        courseware = Courseware(title: fallbackTitle, slides: [Slide()])
        if let doc = try xml("Document.xml"), let name = doc.child("Name")?.text, !name.isEmpty {
            courseware.title = name
        }
        if let ref = try xml("Reference.xml") {
            for rel in ref.descendants("Relationship") {
                guard let id = rel.child("Id")?.text, let target = rel.child("Target")?.text else { continue }
                references[id] = target.replacingOccurrences(of: "\\", with: "/")
            }
        }

        var order: [String] = []
        if let board = try xml("Board.xml") {
            order = board.child("Slides")?.children("Item").compactMap(\.text) ?? []
            if let w = board.child("SlideWidth")?.double, let h = board.child("SlideHeight")?.double, w > 0, h > 0 {
                courseware.slideSize = CGSize(width: w, height: h)
            }
        }

        var parsed: [String: Slide] = [:]
        var sequence: [Slide] = []
        let slidePaths = zip.paths.filter { $0.lowercased().hasPrefix("slides/") && $0.lowercased().hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for path in slidePaths {
            guard let root = try xml(path) else { continue }
            let slideNode = root.name == "Slide" ? root : (root.child("Slide") ?? root)
            let slide = parseSlide(slideNode)
            parsed[slide.id] = slide
            sequence.append(slide)
        }
        guard !sequence.isEmpty else { throw ZipError.corrupt("没有找到课件页面") }
        let ordered = order.compactMap { parsed[$0] }
        courseware.slides = ordered.count == sequence.count ? ordered : sequence
        return courseware
    }

    private func xml(_ path: String) throws -> XMLElement? {
        guard let data = try zip.read(path) else { return nil }
        let doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        return doc.rootElement()
    }

    mutating func parseSlide(_ node: XMLElement) -> Slide {
        var slide = Slide(id: node.child("Id")?.text ?? BoardElement.newID())
        slide.name = node.child("SlideName")?.text
        if let own = node.child("XiwoBackground") {
            // Written by EnbxExporter next to a picture of a patterned background: the
            // background as this app had it, in place of the picture.
            if let c = own.child("Color")?.text.flatMap(RGBA.init(hex:)) { slide.background.color = c }
            if let p = own.child("Pattern")?.text.flatMap(BackgroundPattern.init(rawValue:)) { slide.background.pattern = p }
            if let c = own.child("PatternColor")?.text.flatMap(RGBA.init(hex:)) { slide.background.patternColor = c }
            if let img = own.child("Image")?.text { slide.background.image = resource(for: img) }
        } else if let bg = node.child("Background") {
            if let c = brushColor(bg) { slide.background.color = c }
            if let img = bg.child("ImageBrush")?.child("Source")?.text, let key = resource(for: img) {
                slide.background.image = key
            }
        }
        if let key = node.child("TransitionKey")?.text { slide.transition = Self.transition(named: key) }
        if let note = node.child("SlideNote") {
            slide.notes = note.descendants("Text").compactMap(\.rawText).joined(separator: "\n")
        }
        slide.elements = parseElements(node.child("Elements"))
        return slide
    }

    mutating func parseElements(_ node: XMLElement?) -> [BoardElement] {
        guard let node else { return [] }
        return node.elementChildren.compactMap { parseElement($0) }
    }

    mutating func parseElement(_ node: XMLElement) -> BoardElement? {
        let frame = CGRect(x: node.child("X")?.double ?? 0, y: node.child("Y")?.double ?? 0,
                           width: abs(node.child("Width")?.double ?? 10), height: abs(node.child("Height")?.double ?? 10))
        var element = BoardElement(id: node.child("Id")?.text ?? BoardElement.newID(), frame: frame,
                                   rotation: node.child("Rotation")?.double ?? 0,
                                   locked: node.child("IsLocked")?.bool ?? false,
                                   masked: node.child("HasMask")?.bool ?? false,
                                   cloneOnDrag: node.child("CanClone")?.bool ?? false,
                                   hyperlink: node.child("Hyperlink")?.text,
                                   content: .group([]))
        // Pictures carry theirs as Alpha.
        if let o = (node.child("Opacity") ?? node.child("Alpha"))?.double, o.isFinite { element.opacity = min(1, max(0, o)) }
        switch node.name ?? "" {
        case "Shape":
            var shape = parseShape(node, frame: frame)
            if shape.type.isLine, node.child("XiwoAntiDiagonal")?.bool == true {
                // EnbxExporter turned this line to run the other way; undo the turn.
                shape.antiDiagonal = true
                let turned = (element.rotation - EnbxExporter.antiDiagonalTurn(frame.size)).truncatingRemainder(dividingBy: 360)
                let rounded = (turned * 1000).rounded() / 1000
                element.rotation = abs(rounded) < 0.01 ? 0 : rounded
            }
            element.content = .shape(shape)
        case "Text":
            element.content = .text(parseText(node))
            // Other apps measure text differently; keep every line inside the box so all
            // of it can be clicked.
            element.growToFitText()
        case "Picture":
            guard let src = node.child("Source")?.text, let key = resource(for: src) else {
                warnings.append("图片资源缺失"); return nil
            }
            element.content = .image(ImageSpec(resource: key, name: node.child("PictureName")?.text))
        case "Video", "Audio":
            guard let src = node.child("Source")?.text, let key = resource(for: src) else {
                warnings.append("音视频资源缺失"); return nil
            }
            let name = node.child("MediaName")?.text ?? (node.name == "Video" ? "视频" : "音频")
            element.content = .media(MediaSpec(kind: node.name == "Video" ? .video : .audio, resource: key, name: name))
        case "Group":
            let children = parseElements(node.child("Elements"))
            guard !children.isEmpty else { return nil }
            element.content = .group(children)
        default:
            warnings.append("暂不支持的元素：\(node.name ?? "?")")
            return nil
        }
        return element
    }

    func parseShape(_ node: XMLElement, frame: CGRect) -> ShapeSpec {
        var style = ShapeAppearance()
        if let fg = node.child("Foreground"), let c = brushColor(fg) { style.stroke = c }
        if let bg = node.child("Background"), let c = brushColor(bg), c.a > 0 { style.fill = c }
        if let t = node.child("Thickness")?.double { style.lineWidth = t }
        if node.child("PenSetting")?.child("DashStyle") != nil { style.dashed = true }
        let geometryName = node.child("Geometry")?.descendants("GeometryType").first?.text
        var type = geometryName.flatMap(Self.shapeType(named:)) ?? .custom
        var custom: String?
        if type == .custom {
            custom = node.child("Path")?.text ?? node.child("Geometry")?.descendants("Path").first?.text
                ?? node.child("ShapePaths")?.descendants("Path").first?.text
            if custom == nil { type = .rectangle }
        }
        if type == .line, style.dashed { type = .dottedLine }
        let text = node.child("InlineText").map { Self.plainText(of: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        return ShapeSpec(type: type, style: style, customPath: custom, text: text)
    }

    func parseText(_ node: XMLElement) -> TextSpec {
        let rich = node.child("RichText") ?? node
        var spec = TextSpec(text: Self.plainText(of: rich))
        if let align = rich.descendants("TextAlignment").first?.text?.lowercased() {
            spec.alignment = align.contains("center") ? .center : align.contains("right") ? .right : .left
        }
        if let run = rich.descendants("TextRun").first {
            if let size = run.child("FontSize")?.double { spec.fontSize = size }
            if let fg = run.child("Foreground"), let c = brushColor(fg) { spec.color = c }
            if let w = run.child("FontWeight")?.text { spec.bold = w.lowercased().contains("bold") }
            if let s = run.child("FontStyle")?.text { spec.italic = s.lowercased().contains("italic") }
            if let f = run.child("FontFamily")?.descendants("Source").first?.text?.components(separatedBy: ",").first,
               !f.isEmpty, f.count < 64 {
                spec.fontName = f
            }
            if let decoration = (run.child("Decoration") ?? run.child("TextDecorations"))?.stringValue {
                spec.underline = decoration.lowercased().contains("underline")
            }
        }
        if let fill = node.child("Fill"), let c = brushColor(fill), c.a > 0 { spec.background = c }
        return spec
    }

    /// Page transition for a `TransitionKey`; kinds this app has no counterpart for become none.
    static func transition(named key: String) -> SlideTransition {
        let k = key.lowercased()
        if k.contains("fade") { return .fade }
        if k.contains("push") { return .push }
        if k.contains("reveal") || k.contains("uncover") { return .reveal }
        return .none
    }

    /// Joins `TextRun` texts, one line per `TextLine` (RichText > TextLines > TextLine > TextRuns > TextRun).
    static func plainText(of node: XMLElement) -> String {
        let lines = node.descendants("TextLine")
        if !lines.isEmpty {
            return lines.map { $0.descendants("TextRun").compactMap { $0.child("Text")?.rawText }.joined() }
                .joined(separator: "\n")
        }
        let runs = node.descendants("TextRun").compactMap { $0.child("Text")?.rawText }
        if !runs.isEmpty { return runs.joined() }
        return node.child("Text")?.rawText ?? ""
    }

    static func shapeType(named name: String) -> ShapeType? {
        let synonyms: [String: ShapeType] = ["ellipse": .circle, "oval": .circle, "hexagon": .polygon,
                                             "parallelogram": .rhomboid, "diamond": .rhombus, "heart": .love,
                                             "pentagram": .star, "arrow": .arrowEnd, "doublearrow": .arrowStartEnd]
        let key = name.lowercased()
        if let s = synonyms[key] { return s }
        return ShapeType.allCases.first { $0.rawValue.lowercased() == key }
    }

    func brushColor(_ node: XMLElement) -> RGBA? {
        if let c = node.child("ColorBrush")?.text { return RGBA(hex: c) }
        if let stop = node.descendants("GradientStop").first?.child("Color")?.text { return RGBA(hex: stop) }
        if let t = node.text, t.hasPrefix("#") { return RGBA(hex: t) }
        if let c = node.child("Color")?.text { return RGBA(hex: c) }
        return nil
    }

    /// Resolves `id://<ref>` (via Reference.xml) or a direct path to a resource key.
    mutating func resource(for uri: String) -> String? {
        var path: String?
        if uri.hasPrefix("id://") {
            let id = String(uri.dropFirst(5))
            path = references[id] ?? "Resources/\(id)"
        } else if !uri.hasPrefix("http") {
            path = uri.replacingOccurrences(of: "\\", with: "/")
        }
        guard let path else { return nil }
        if let key = resourceKeys[path] { return key }
        guard let data = try? zip.read(path) else { return nil }
        let ext = Self.sniffExtension(data) ?? URL(fileURLWithPath: path).pathExtension
        let key = courseware.addResource(data: data, name: URL(fileURLWithPath: path).lastPathComponent, ext: ext)
        resourceKeys[path] = key
        return key
    }

    static func sniffExtension(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count >= 12, b[4...7] == [0x66, 0x74, 0x79, 0x70] { return "mp4" }
        if b.starts(with: [0x49, 0x44, 0x33]) || b.starts(with: [0xFF, 0xFB]) { return "mp3" }
        if b.starts(with: [0x52, 0x49, 0x46, 0x46]) { return b.count >= 12 && b[8] == 0x57 ? "webp" : "wav" }
        return nil
    }
}

extension XMLElement {
    var elementChildren: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }
    func child(_ name: String) -> XMLElement? { elementChildren.first { $0.name == name } }
    func children(_ name: String) -> [XMLElement] { elementChildren.filter { $0.name == name } }
    func descendants(_ name: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for c in elementChildren {
            if c.name == name { out.append(c) }
            out.append(contentsOf: c.descendants(name))
        }
        return out
    }
    var text: String? {
        guard elementChildren.isEmpty else { return nil }
        return stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// A leaf's text exactly as written, spaces at either end included.
    var rawText: String? {
        guard elementChildren.isEmpty else { return nil }
        return stringValue
    }
    var double: Double? { text.flatMap(Double.init) }
    var bool: Bool? { text.map { $0.lowercased() == "true" } }
}
