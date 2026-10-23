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

/// Current tool and its settings, shared by the editor and the presenter.
@MainActor
final class ToolState: ObservableObject {
    @Published var tool: Tool = .select
    @Published var penColor: RGBA = .red
    @Published var penWidth: Double = 4
    @Published var penKind: PenKind = .pen
    @Published var eraserSize: Double = 40
    @Published var eraserMode: EraserMode = .area
    @Published var shapeStyle = ShapeAppearance(stroke: RGBA(0.13, 0.45, 0.95), fill: nil, lineWidth: 4)
    @Published var textSpec = TextSpec(text: "", fontSize: 36)
    @Published var spotlightRadius: Double = 160
    @Published var magnifierZoom: Double = 2

    static let penWidths: [Double] = [1, 2, 4, 8, 14, 24]
}
