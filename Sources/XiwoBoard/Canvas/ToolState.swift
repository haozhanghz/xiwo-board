import Combine
import Foundation
import XiwoCore

enum Tool: Equatable {
    case select
    case pen
    case eraser
    case laser
    case shape(ShapeType)
    case text
    /// Darkens the board except a circle around the pointer (聚光灯).
    case spotlight
    /// Enlarges the board under the pointer (放大镜).
    case magnifier

    var isOverlay: Bool { self == .spotlight || self == .magnifier || self == .laser }
}

enum EraserMode: String, CaseIterable {
    /// Rubs out the ink under the eraser (点擦).
    case area
    /// Deletes whole strokes it touches (笔画擦).
    case stroke

    var label: String { self == .area ? "点擦" : "笔画擦" }
}

/// How much the pens steady the line as it is written (防抖).
enum PenSteadiness: String, CaseIterable {
    case off, light, medium, strong

    var label: String {
        switch self {
        case .off: "关"
        case .light: "轻"
        case .medium: "中"
        case .strong: "强"
        }
    }

    /// How far along the stroke `StrokeSmoother` reaches, in view points: about the size of
    /// the wobbles it takes out. A tablet's jitter and a slight shake of the hand are a
    /// point or two on screen; the strongest setting also irons out a shakier hand, but
    /// begins to round off small handwriting.
    var sigma: Double {
        switch self {
        case .off: 0
        case .light: 1.5
        case .medium: 2.5
        case .strong: 4
        }
    }
}

/// Current tool and its settings, shared by the editor and the presenter.
@MainActor
final class ToolState: ObservableObject {
    @Published var tool: Tool = .select
    @Published var penColor: RGBA = .red
    @Published var penWidth: Double = 4
    @Published var penKind: PenKind = .pen
    /// The hard pen writes with a nib (笔锋): thinner when fast, pointed when flicked off.
    @Published var penNib = ToolState.savedPenNib {
        didSet { UserDefaults.standard.set(penNib, forKey: "PenNib") }
    }
    @Published var penSteadiness = ToolState.savedPenSteadiness {
        didSet { UserDefaults.standard.set(penSteadiness.rawValue, forKey: "PenSteadiness") }
    }
    @Published var eraserSize: Double = 40
    @Published var eraserMode: EraserMode = .area
    @Published var shapeStyle = ShapeAppearance(stroke: RGBA(0.13, 0.45, 0.95), fill: nil, lineWidth: 4)
    @Published var textSpec = TextSpec(text: "", fontSize: 36)
    @Published var spotlightRadius: Double = 160
    @Published var magnifierZoom: Double = 2

    static let penWidths: [Double] = [1, 2, 4, 8, 14, 24]
    /// The nib as last set; on until someone turns it off.
    static var savedPenNib: Bool { UserDefaults.standard.object(forKey: "PenNib") as? Bool ?? true }
    /// The steadiness as last set; medium until someone changes it.
    static var savedPenSteadiness: PenSteadiness {
        UserDefaults.standard.string(forKey: "PenSteadiness").flatMap(PenSteadiness.init) ?? .medium
    }
}
