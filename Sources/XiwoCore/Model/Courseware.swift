import CoreGraphics
import Foundation

/// Background pattern drawn over the slide colour.
public enum BackgroundPattern: String, Codable, CaseIterable, Sendable {
    case none
    /// Square grid (方格).
    case grid
    /// Four-line three-space ruling for pinyin and English handwriting (四线三格).
    case fourLines
    /// Tian-zi-ge practice boxes for Chinese characters (田字格).
    case tianzige
    /// Plain ruled lines (横线).
    case ruled
    /// Dot grid (点阵).
    case dots

    public var displayName: String {
        switch self {
        case .none: return "无"
        case .grid: return "方格"
        case .fourLines: return "四线三格"
        case .tianzige: return "田字格"
        case .ruled: return "横线"
        case .dots: return "点阵"
        }
    }
}

public struct SlideBackground: Codable, Hashable, Sendable {
    public var color: RGBA
    public var pattern: BackgroundPattern
    public var patternColor: RGBA
    /// Optional full-bleed picture (resource key).
    public var image: String?

    public init(color: RGBA = .white, pattern: BackgroundPattern = .none,
                patternColor: RGBA = RGBA(0.55, 0.7, 0.85), image: String? = nil) {
        self.color = color; self.pattern = pattern; self.patternColor = patternColor; self.image = image
    }

    /// Preset backgrounds in the 背景 panel.
    public static let presets: [SlideBackground] = [
        SlideBackground(),
        SlideBackground(color: .chalkboard, patternColor: RGBA(1, 1, 1, 0.35)),
        SlideBackground(color: RGBA(0.12, 0.12, 0.14), patternColor: RGBA(1, 1, 1, 0.3)),
        SlideBackground(color: RGBA(0.99, 0.97, 0.90)),
        SlideBackground(color: RGBA(0.90, 0.95, 1.0)),
        SlideBackground(pattern: .grid),
        SlideBackground(pattern: .fourLines, patternColor: RGBA(0.85, 0.3, 0.3)),
        SlideBackground(pattern: .tianzige, patternColor: RGBA(0.2, 0.6, 0.3)),
        SlideBackground(pattern: .ruled),
        SlideBackground(pattern: .dots),
        SlideBackground(color: .chalkboard, pattern: .grid, patternColor: RGBA(1, 1, 1, 0.25)),
    ]
}

public struct Slide: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var background: SlideBackground
    public var elements: [BoardElement]
    /// Teacher notes (备注), not shown while presenting.
    public var notes: String
    public var transition: SlideTransition

    public init(id: String = BoardElement.newID(), name: String? = nil, background: SlideBackground = SlideBackground(),
                elements: [BoardElement] = [], notes: String = "", transition: SlideTransition = .none) {
        self.id = id; self.name = name; self.background = background
        self.elements = elements; self.notes = notes; self.transition = transition
    }

    public func element(id: String) -> BoardElement? { elements.first { $0.id == id } }

    public func duplicated() -> Slide {
        var s = self
        s.id = BoardElement.newID()
        s.elements = elements.map { $0.duplicated() }
        return s
    }
}

public enum SlideTransition: String, Codable, CaseIterable, Sendable {
    case none, fade, push, reveal

    public var displayName: String {
        switch self {
        case .none: return "无"
        case .fade: return "淡入"
        case .push: return "推入"
        case .reveal: return "揭开"
        }
    }
}

/// A resource blob (picture, audio, video) referenced from elements.
public struct Resource: Codable, Hashable, Sendable {
    public var name: String
    /// File extension without dot, e.g. "png".
    public var ext: String
    public var data: Data

    public init(name: String, ext: String, data: Data) {
        self.name = name; self.ext = ext; self.data = data
    }
}

/// A courseware document (课件).
public struct Courseware: Codable, Hashable, Sendable {
    public static let defaultSize = CGSize(width: 1280, height: 720)

    public var title: String
    public var slideSize: CGSize
    public var slides: [Slide]
    public var resources: [String: Resource]
    public var created: Date
    public var modified: Date

    public init(title: String = "未命名课件", slideSize: CGSize = Courseware.defaultSize,
                slides: [Slide] = [Slide()], resources: [String: Resource] = [:]) {
        self.title = title; self.slideSize = slideSize
        self.slides = slides.isEmpty ? [Slide()] : slides
        self.resources = resources
        self.created = Date(); self.modified = Date()
    }

    /// Adds `data` to the resource table, de-duplicating identical content.
    @discardableResult
    public mutating func addResource(data: Data, name: String, ext: String) -> String {
        let key = ContentHash.hex(of: data)
        if resources[key] == nil { resources[key] = Resource(name: name, ext: ext.lowercased(), data: data) }
        return key
    }

    /// Drops resources no element or background references.
    public mutating func pruneResources() {
        var used = Set<String>()
        func visit(_ e: BoardElement) {
            switch e.content {
            case .image(let i): used.insert(i.resource)
            case .media(let m): used.insert(m.resource)
            case .group(let g): g.forEach(visit)
            default: break
            }
        }
        for s in slides {
            s.elements.forEach(visit)
            if let img = s.background.image { used.insert(img) }
        }
        resources = resources.filter { used.contains($0.key) }
    }
}
