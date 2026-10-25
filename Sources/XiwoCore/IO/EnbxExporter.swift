import CoreGraphics
import Foundation
import ImageIO

/// Writes the subset of our model that maps onto `.enbx` structures
/// (shapes, text, pictures, media, groups; ink is written as path shapes).
/// The layout matches what `EnbxImporter` reads; see that type for the format notes.
/// What has no enbx form at all is listed by `losses(in:)`; a few things this app needs
/// back are kept in extra `Xiwo…` fields that other readers skip.
public enum EnbxExporter {
    public static func encode(_ courseware: Courseware) -> Data {
        var cw = courseware
        cw.pruneResources()
        // Writing patterns (书写格) have no enbx form, so a patterned page gets a picture of
        // its whole background, which any reader shows; XiwoBackground keeps the pattern
        // itself for this app to read back.
        var backgroundPictures: [String: String] = [:]
        for slide in cw.slides where slide.background.pattern != .none {
            if let png = backgroundPicture(slide.background, courseware: cw) {
                backgroundPictures[slide.id] = cw.addResource(data: png, name: "背景.png", ext: "png")
            }
        }
        var zip = ZipWriter()
        let stamp = Self.timestamp()
        zip.add("Document.xml", data: xml(node("Document", [
            leaf("Name", cw.title), leaf("Creator", "XiwoBoard"), leaf("LastModifiedBy", "XiwoBoard"),
            leaf("CreatedDateTime", stamp), leaf("ModifiedDateTime", stamp),
            leaf("CreatedDocumentVersion", "1.0"), leaf("DocumentVersion", "1.0"),
            leaf("CreatedAppVersion", "XiwoBoard.1"), leaf("AppVersion", "XiwoBoard.1"), leaf("DocumentExtraInfo", ""),
        ])))
        zip.add("Board.xml", data: xml(node("Board", [
            leaf("SlideWidth", num(cw.slideSize.width)), leaf("SlideHeight", num(cw.slideSize.height)),
            node("Slides", cw.slides.map { leaf("Item", $0.id) }),
        ])))
        var rels: [XNode] = []
        for (key, r) in cw.resources.sorted(by: { $0.key < $1.key }) {
            zip.add("Resources/\(key)", data: r.data, compress: false)
            rels.append(node("Relationship", [leaf("Id", key), leaf("Target", "Resources\\\(key)"), leaf("Hash", key)]))
        }
        zip.add("Reference.xml", data: xml(node("Reference", [node("Relationships", rels)])))
        for (i, slide) in cw.slides.enumerated() {
            zip.add("Slides/Slide_\(i).xml", data: xml(slideNode(slide, size: cw.slideSize, picture: backgroundPictures[slide.id])))
        }
        return zip.finish()
    }

    /// What an enbx export of `courseware` cannot keep as it is, in words for the person
    /// exporting; empty when everything maps.
    public static func losses(in courseware: Courseware) -> [String] {
        var found: [String] = []
        func note(_ loss: String) { if !found.contains(loss) { found.append(loss) } }
        func visit(_ e: BoardElement) {
            switch e.content {
            case .stroke(let s):
                note("笔迹会变成线条形状，之后不能再用橡皮擦除")
                if s.kind != .pen { note("毛笔的粗细变化和荧光笔压在文字下面的效果不保留") }
                if s.hasNib { note("硬笔的笔锋不保留，线条会变得粗细一致") }
            case .table:
                note("表格会变成纯文本")
            case .media(let m) where m.autoPlay || m.loop:
                note("音视频的自动播放和循环播放设置不保留")
            case .group(let children):
                children.forEach(visit)
            default:
                break
            }
        }
        for slide in courseware.slides {
            if slide.background.pattern != .none { note("书写格背景会存成一张背景图片") }
            slide.elements.forEach(visit)
        }
        return found
    }

    /// The page background, pattern included, as a PNG at twice the page size (at most 4K).
    static func backgroundPicture(_ background: SlideBackground, courseware: Courseware) -> Data? {
        let size = courseware.slideSize
        let scale = min(2, 3840 / max(size.width, size.height))
        guard scale.isFinite, scale > 0,
              let image = SlideRenderer.image(of: Slide(background: background), courseware: courseware,
                                              pixelWidth: Int((size.width * scale).rounded())) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func slideNode(_ s: Slide, size: CGSize, picture: String? = nil) -> XNode {
        var bg: [XNode] = [leaf("ColorBrush", s.background.color.argbHex)]
        if let img = picture ?? s.background.image {
            bg = [node("ImageBrush", [leaf("Source", "id://\(img)"), leaf("Stretch", "Fill"), leaf("Opacity", "1")])]
        }
        var children: [XNode] = [leaf("Id", s.id), leaf("Width", num(size.width)), leaf("Height", num(size.height)),
                                 node("Background", bg)]
        if picture != nil {
            var own = [leaf("Color", s.background.color.argbHex), leaf("Pattern", s.background.pattern.rawValue),
                       leaf("PatternColor", s.background.patternColor.argbHex)]
            if let img = s.background.image { own.append(leaf("Image", "id://\(img)")) }
            children.append(node("XiwoBackground", own))
        }
        if let name = s.name, !name.isEmpty { children.append(leaf("SlideName", name)) }
        if s.transition != .none { children.append(leaf("TransitionKey", transitionKey(s.transition))) }
        children.append(leaf("Duration", "5000000"))
        if !s.notes.isEmpty { children.append(node("SlideNote", [leaf("Text", s.notes)])) }
        children.append(node("Elements", s.elements.map(elementNode)))
        return node("Slide", children)
    }

    /// `TransitionKey` value for a page transition: "Fade", "Push", "Reveal".
    static func transitionKey(_ t: SlideTransition) -> String {
        t.rawValue.prefix(1).uppercased() + t.rawValue.dropFirst()
    }

    /// enbx lines run from the top-left corner of their box to the bottom-right. Turned by
    /// this many degrees about its centre, such a line runs from the bottom-left corner to
    /// the top-right instead, as an anti-diagonal line (like a y axis) does.
    static func antiDiagonalTurn(_ size: CGSize) -> Double {
        -2 * atan2(Double(size.height), Double(size.width)) * 180 / .pi
    }

    static func base(_ e: BoardElement, rotation: Double? = nil) -> [XNode] {
        var out = [leaf("Id", e.id), leaf("X", num(e.frame.minX)), leaf("Y", num(e.frame.minY)),
                   leaf("Width", num(e.frame.width)), leaf("Height", num(e.frame.height)),
                   leaf("Rotation", num(rotation ?? e.rotation)), leaf("IsLocked", bool(e.locked)),
                   leaf("CanClone", bool(e.cloneOnDrag)), leaf("HasMask", bool(e.masked))]
        if let link = e.hyperlink { out.append(leaf("Hyperlink", link)) }
        return out
    }

    static func elementNode(_ e: BoardElement) -> XNode {
        switch e.content {
        case .shape(let s):
            // A line drawn the other way is turned to match, and marked so this app reads
            // it back as it was drawn.
            let anti = s.type.isLine && s.antiDiagonal == true
            var c = base(e, rotation: anti ? e.rotation + antiDiagonalTurn(e.frame.size) : nil)
            if anti { c.append(leaf("XiwoAntiDiagonal", "True")) }
            c.append(node("Foreground", [leaf("ColorBrush", s.style.stroke.argbHex)]))
            c.append(node("Background", [leaf("ColorBrush", (s.style.fill ?? .clear).argbHex)]))
            c.append(leaf("Thickness", num(s.style.lineWidth)))
            c.append(leaf("Opacity", num(e.opacity)))
            if s.type == .custom, let p = s.customPath {
                c.append(leaf("Path", p))
            } else {
                c.append(node("Geometry", [node("PresetGeometry", [leaf("GeometryType", presetName(s.type))])]))
            }
            if s.style.dashed {
                c.append(node("PenSetting", [node("DashStyle", [node("Dashes", [leaf("Item", "2"), leaf("Item", "2")]), leaf("Offset", "0")])]))
            }
            if let t = s.text, !t.isEmpty { c.append(node("InlineText", [richText(TextSpec(text: t, fontSize: 24, alignment: .center))])) }
            return node("Shape", c)
        case .stroke(let st):
            var c = base(e)
            c.append(node("Foreground", [leaf("ColorBrush", st.color.withAlpha(st.kind == .highlighter ? 0.4 : st.color.a).argbHex)]))
            c.append(node("Background", [leaf("ColorBrush", RGBA.clear.argbHex)]))
            c.append(leaf("Thickness", num(st.width)))
            c.append(leaf("Path", strokePath(st)))
            return node("Shape", c)
        case .text(let t):
            var c = base(e)
            c.append(richText(t))
            if let bg = t.background { c.append(leaf("Fill", bg.argbHex)) }
            c.append(leaf("Opacity", num(e.opacity)))
            return node("Text", c)
        case .image(let img):
            var c = base(e)
            c.append(leaf("Source", "id://\(img.resource)"))
            c.append(leaf("PictureName", img.name ?? "图片"))
            c.append(leaf("Alpha", num(e.opacity)))
            return node("Picture", c)
        case .media(let m):
            var c = base(e)
            c.append(leaf("Source", "id://\(m.resource)"))
            c.append(leaf("MediaName", m.name))
            c.append(leaf("Opacity", num(e.opacity)))
            return node(m.kind == .video ? "Video" : "Audio", c)
        case .table(let t):
            // No public table schema; flatten to text so content survives the trip.
            var c = base(e)
            c.append(richText(TextSpec(text: t.cells.map { $0.joined(separator: "\t") }.joined(separator: "\n"), fontSize: t.fontSize)))
            c.append(leaf("Opacity", num(e.opacity)))
            return node("Text", c)
        case .group(let g):
            var c = base(e)
            c.append(leaf("Opacity", num(e.opacity)))
            c.append(node("Elements", g.map(elementNode)))
            return node("Group", c)
        }
    }

    static func richText(_ t: TextSpec) -> XNode {
        let align = t.alignment == .center ? "Center" : t.alignment == .right ? "Right" : "Left"
        let lines = t.text.components(separatedBy: "\n").map { line -> XNode in
            node("TextLine", [
                leaf("TextAlignment", align), leaf("LineSpacing", "1"),
                node("TextRuns", [node("TextRun", [
                    leaf("Text", line), leaf("FontSize", num(t.fontSize)),
                    node("FontFamily", [leaf("Source", t.fontName)]),
                    leaf("FontWeight", t.bold ? "Bold" : "Normal"), leaf("FontStyle", t.italic ? "Italic" : "Normal"),
                    node("Foreground", [leaf("ColorBrush", t.color.argbHex)]),
                    leaf("Decoration", t.underline ? "Underline" : ""),
                ])]),
            ])
        }
        return node("RichText", [leaf("Text", t.text), node("TextLines", lines)])
    }

    static func strokePath(_ s: Stroke) -> String {
        guard let first = s.points.first else { return "" }
        var out = "M \(num(first.x)),\(num(first.y))"
        for p in s.points.dropFirst() { out += " L \(num(p.x)),\(num(p.y))" }
        return out
    }

    static func presetName(_ t: ShapeType) -> String {
        let raw = t.rawValue
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    static func num(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e12 { return String(Int(v)) }
        return String(format: "%.3f", v)
    }
    static func num(_ v: CGFloat) -> String { num(Double(v)) }
    static func bool(_ b: Bool) -> String { b ? "True" : "False" }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - Tiny XML builder

    indirect enum XNode {
        case element(String, [XNode])
        case text(String, String)
    }

    static func node(_ name: String, _ children: [XNode]) -> XNode { .element(name, children) }
    static func leaf(_ name: String, _ value: String) -> XNode { .text(name, value) }

    static func xml(_ root: XNode) -> Data {
        var s = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        func write(_ n: XNode, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            switch n {
            case .text(let name, let v):
                s += v.isEmpty ? "\(pad)<\(name)/>\n" : "\(pad)<\(name)>\(escape(v))</\(name)>\n"
            case .element(let name, let kids):
                if kids.isEmpty { s += "\(pad)<\(name)/>\n"; return }
                s += "\(pad)<\(name)>\n"
                kids.forEach { write($0, depth + 1) }
                s += "\(pad)</\(name)>\n"
            }
        }
        write(root, 0)
        return Data(s.utf8)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
