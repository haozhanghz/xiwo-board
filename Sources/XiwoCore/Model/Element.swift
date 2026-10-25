import CoreGraphics
import Foundation

public struct StrokePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    /// Normalised pen pressure, 0...1. Mouse input reports 1.
    public var pressure: Double
    /// The line's width here as a fraction of the stroke's width, written by a pen with a
    /// nib (`PenNib`). Nil keeps the stroke's own width, as ink from before nibs does.
    public var widthScale: Double?

    public init(x: Double, y: Double, pressure: Double = 1, widthScale: Double? = nil) {
        self.x = x; self.y = y; self.pressure = pressure; self.widthScale = widthScale
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    /// The same point, moved.
    public func offsetBy(dx: Double, dy: Double) -> StrokePoint {
        var p = self
        p.x += dx; p.y += dy
        return p
    }

    // Every point of a stroke stores its width, so the key is short.
    private enum CodingKeys: String, CodingKey { case x, y, pressure, widthScale = "w" }
}

public enum PenKind: String, Codable, CaseIterable, Sendable {
    /// Hard pen: uniform width.
    case pen
    /// Brush pen: width follows pressure and speed.
    case brush
    /// Translucent highlighter drawn under other ink.
    case highlighter
}

public struct Stroke: Codable, Hashable, Sendable {
    /// Points in element-local coordinates (relative to the element frame's origin).
    public var points: [StrokePoint]
    public var color: RGBA
    public var width: Double
    public var kind: PenKind

    public init(points: [StrokePoint], color: RGBA, width: Double, kind: PenKind = .pen) {
        self.points = points; self.color = color; self.width = width; self.kind = kind
    }

    /// A hard pen whose width changes along the line (笔锋).
    public var hasNib: Bool { kind == .pen && points.contains { $0.widthScale != nil } }

    /// How far the ink reaches out from its points: half the widest the line gets.
    public var reach: Double {
        guard hasNib else { return width / 2 }
        return width / 2 * points.reduce(1) { max($0, $1.widthScale ?? 1) }
    }
}

public struct ShapeAppearance: Codable, Hashable, Sendable {
    public var stroke: RGBA
    public var fill: RGBA?
    public var lineWidth: Double
    public var dashed: Bool

    public init(stroke: RGBA = .black, fill: RGBA? = nil, lineWidth: Double = 3, dashed: Bool = false) {
        self.stroke = stroke; self.fill = fill; self.lineWidth = lineWidth; self.dashed = dashed
    }
}

public struct ShapeSpec: Codable, Hashable, Sendable {
    public var type: ShapeType
    public var style: ShapeAppearance
    /// Custom outline in element-local coordinates, used by imported shapes whose
    /// geometry is an arbitrary path rather than one of the presets.
    public var customPath: String?
    /// Text drawn centred inside the shape.
    public var text: String?
    /// Line shapes run corner to corner; `true` means bottom-left to top-right
    /// instead of top-left to bottom-right.
    public var antiDiagonal: Bool?

    public init(type: ShapeType, style: ShapeAppearance = ShapeAppearance(), customPath: String? = nil, text: String? = nil,
                antiDiagonal: Bool? = nil) {
        self.type = type; self.style = style; self.customPath = customPath; self.text = text
        self.antiDiagonal = antiDiagonal
    }

    /// End points of a line shape inside `rect`.
    public func lineEnds(in rect: CGRect) -> (CGPoint, CGPoint) {
        antiDiagonal == true
            ? (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY))
            : (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
    }
}

public enum TextAlignment: String, Codable, CaseIterable, Sendable {
    case left, center, right
}

public struct TextSpec: Codable, Hashable, Sendable {
    public var text: String
    public var fontName: String
    public var fontSize: Double
    public var color: RGBA
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var alignment: TextAlignment
    public var background: RGBA?

    public init(text: String, fontName: String = "PingFang SC", fontSize: Double = 32, color: RGBA = .black,
                bold: Bool = false, italic: Bool = false, underline: Bool = false,
                alignment: TextAlignment = .left, background: RGBA? = nil) {
        self.text = text; self.fontName = fontName; self.fontSize = fontSize; self.color = color
        self.bold = bold; self.italic = italic; self.underline = underline
        self.alignment = alignment; self.background = background
    }
}

public struct ImageSpec: Codable, Hashable, Sendable {
    /// Key into `Courseware.resources`.
    public var resource: String
    public var name: String?

    public init(resource: String, name: String? = nil) {
        self.resource = resource; self.name = name
    }
}

public enum MediaKind: String, Codable, Sendable { case audio, video }

public struct MediaSpec: Codable, Hashable, Sendable {
    public var kind: MediaKind
    public var resource: String
    public var name: String
    public var autoPlay: Bool
    public var loop: Bool

    public init(kind: MediaKind, resource: String, name: String, autoPlay: Bool = false, loop: Bool = false) {
        self.kind = kind; self.resource = resource; self.name = name; self.autoPlay = autoPlay; self.loop = loop
    }
}

public struct TableSpec: Codable, Hashable, Sendable {
    public var rows: Int
    public var columns: Int
    public var cells: [[String]]
    public var fontSize: Double
    public var borderColor: RGBA
    public var headerFill: RGBA?

    public init(rows: Int, columns: Int, fontSize: Double = 22, borderColor: RGBA = RGBA(0.3, 0.3, 0.3),
                headerFill: RGBA? = RGBA(0.86, 0.92, 1.0)) {
        self.rows = max(1, rows); self.columns = max(1, columns)
        self.cells = Array(repeating: Array(repeating: "", count: max(1, columns)), count: max(1, rows))
        self.fontSize = fontSize; self.borderColor = borderColor; self.headerFill = headerFill
    }
}

public indirect enum ElementContent: Codable, Hashable, Sendable {
    case stroke(Stroke)
    case shape(ShapeSpec)
    case text(TextSpec)
    case image(ImageSpec)
    case media(MediaSpec)
    case table(TableSpec)
    case group([BoardElement])
}

public struct BoardElement: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// Frame in slide coordinates (origin top-left, y grows downwards).
    public var frame: CGRect
    /// Rotation in degrees, clockwise, around the frame centre.
    public var rotation: Double
    public var opacity: Double
    public var locked: Bool
    /// "Mask" (蒙层): drawn as an opaque cover that the teacher can tap away while presenting.
    public var masked: Bool
    /// "Clone mode" (克隆): dragging the element while presenting drops a copy.
    public var cloneOnDrag: Bool
    public var hyperlink: String?
    public var content: ElementContent

    public init(id: String = BoardElement.newID(), frame: CGRect, rotation: Double = 0, opacity: Double = 1,
                locked: Bool = false, masked: Bool = false, cloneOnDrag: Bool = false,
                hyperlink: String? = nil, content: ElementContent) {
        self.id = id; self.frame = frame; self.rotation = rotation; self.opacity = opacity
        self.locked = locked; self.masked = masked; self.cloneOnDrag = cloneOnDrag
        self.hyperlink = hyperlink; self.content = content
    }

    public static func newID() -> String { UUID().uuidString.lowercased() }

    public var isStroke: Bool { if case .stroke = content { return true } else { return false } }

    /// A short Chinese label for the layer list and accessibility.
    public var kindLabel: String {
        switch content {
        case .stroke: return "笔迹"
        case .shape(let s): return s.type.displayName
        case .text: return "文本"
        case .image: return "图片"
        case .media(let m): return m.kind == .audio ? "音频" : "视频"
        case .table: return "表格"
        case .group: return "组合"
        }
    }

    /// Returns a copy with fresh ids (recursively for groups), offset by `dx`, `dy`.
    public func duplicated(dx: Double = 0, dy: Double = 0) -> BoardElement {
        var copy = self
        copy.id = BoardElement.newID()
        copy.frame = frame.offsetBy(dx: dx, dy: dy)
        if case .group(let children) = content {
            copy.content = .group(children.map { $0.duplicated(dx: dx, dy: dy) })
        }
        return copy
    }
}
