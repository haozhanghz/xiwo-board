import CoreGraphics
import Foundation

/// Preset shapes offered by the 形状 panel. The set mirrors the shape catalogue
/// of classroom whiteboard software; the geometry here is our own.
public enum ShapeType: String, Codable, CaseIterable, Sendable {
    case line, dottedLine, lineArrowEnd, lineArrowStartEnd
    case rectangle, roundRectangle, circle, fan, triangle, rightTriangle
    case rhomboid, rhombus, trapezoid, polygon, star, love, curveRhombus
    case brace, bracket, thunder, fire, moon, sun, cloud, smilingFace, bomb
    case scroll, banner, medal
    case arrowEnd, arrowStartEnd, arrowSwallow, curveArrow, rotationArrow
    case flag, rectangleMark, circleBubble, rectangleBubble, bubble
    /// Imported outline that is not one of the presets.
    case custom

    public static var palette: [ShapeType] { allCases.filter { $0 != .custom } }

    public var displayName: String {
        switch self {
        case .line: return "直线"
        case .dottedLine: return "虚线"
        case .lineArrowEnd: return "单箭头线"
        case .lineArrowStartEnd: return "双箭头线"
        case .rectangle: return "矩形"
        case .roundRectangle: return "圆角矩形"
        case .circle: return "圆形"
        case .fan: return "扇形"
        case .triangle: return "三角形"
        case .rightTriangle: return "直角三角形"
        case .rhomboid: return "平行四边形"
        case .rhombus: return "菱形"
        case .trapezoid: return "梯形"
        case .polygon: return "六边形"
        case .star: return "五角星"
        case .love: return "爱心"
        case .curveRhombus: return "四角星"
        case .brace: return "大括号"
        case .bracket: return "中括号"
        case .thunder: return "闪电"
        case .fire: return "火焰"
        case .moon: return "月亮"
        case .sun: return "太阳"
        case .cloud: return "云朵"
        case .smilingFace: return "笑脸"
        case .bomb: return "爆炸"
        case .scroll: return "卷轴"
        case .banner: return "横幅"
        case .medal: return "奖牌"
        case .arrowEnd: return "右箭头"
        case .arrowStartEnd: return "双向箭头"
        case .arrowSwallow: return "燕尾箭头"
        case .curveArrow: return "弧形箭头"
        case .rotationArrow: return "环形箭头"
        case .flag: return "旗帜"
        case .rectangleMark: return "标签"
        case .circleBubble: return "圆形气泡"
        case .rectangleBubble: return "矩形气泡"
        case .bubble: return "思考气泡"
        case .custom: return "自定义形状"
        }
    }

    /// Line-like shapes are drawn without fill and resize along their diagonal.
    public var isLine: Bool {
        switch self {
        case .line, .dottedLine, .lineArrowEnd, .lineArrowStartEnd: return true
        default: return false
        }
    }

    /// Open outlines that should never be filled.
    public var isOpen: Bool {
        isLine || self == .brace || self == .bracket
    }
}
