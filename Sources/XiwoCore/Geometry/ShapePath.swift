import CoreGraphics
import Foundation

/// Builds outlines for the preset shapes. Every shape is described in a unit
/// square (0...1 on both axes, y down) and then scaled into the target rect.
public enum ShapePath {
    public static func path(for spec: ShapeSpec, in rect: CGRect) -> CGPath {
        if spec.type.isLine {
            let (a, b) = spec.lineEnds(in: rect)
            let p = CGMutablePath()
            p.move(to: a); p.addLine(to: b)
            return p
        }
        return path(for: spec.type, in: rect, customPath: spec.customPath)
    }

    public static func path(for type: ShapeType, in rect: CGRect, customPath: String? = nil) -> CGPath {
        if type == .custom, let customPath, let p = WPFPathParser.parse(customPath) {
            // Custom outlines are fitted bounding-box-to-frame, so resizing the element scales them.
            let b = p.boundingBoxOfPath
            let sx = b.width > 0.5 ? rect.width / b.width : 1
            let sy = b.height > 0.5 ? rect.height / b.height : 1
            var t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: sx, y: sy)
                .translatedBy(x: -b.minX, y: -b.minY)
            return p.copy(using: &t) ?? p
        }
        let unit = unitPath(for: type)
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: max(rect.width, 0.001), y: max(rect.height, 0.001))
        return unit.copy(using: &t) ?? unit
    }

    /// Arrow heads for line shapes, in slide coordinates.
    public static func arrowHeads(for spec: ShapeSpec, in rect: CGRect) -> CGPath? {
        let type = spec.type
        guard type == .lineArrowEnd || type == .lineArrowStartEnd else { return nil }
        let p = CGMutablePath()
        let (start, end) = spec.lineEnds(in: rect)
        let size = max(12, spec.style.lineWidth * 4)
        addArrowHead(p, from: start, to: end, size: size)
        if type == .lineArrowStartEnd { addArrowHead(p, from: end, to: start, size: size) }
        return p
    }

    private static func addArrowHead(_ p: CGMutablePath, from: CGPoint, to: CGPoint, size: Double) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let spread = Double.pi / 7
        p.move(to: to)
        p.addLine(to: CGPoint(x: to.x - size * cos(angle - spread), y: to.y - size * sin(angle - spread)))
        p.addLine(to: CGPoint(x: to.x - size * cos(angle + spread), y: to.y - size * sin(angle + spread)))
        p.closeSubpath()
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func unitPath(for type: ShapeType) -> CGPath {
        let p = CGMutablePath()
        func poly(_ pts: [(Double, Double)]) {
            guard let f = pts.first else { return }
            p.move(to: CGPoint(x: f.0, y: f.1))
            for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
            p.closeSubpath()
        }
        func regular(_ n: Int, inner: Double? = nil, rotation: Double = -Double.pi / 2) {
            var pts: [(Double, Double)] = []
            let count = inner == nil ? n : n * 2
            for i in 0..<count {
                let r = (inner != nil && i % 2 == 1) ? inner! : 0.5
                let a = rotation + Double(i) * 2 * Double.pi / Double(count)
                pts.append((0.5 + r * cos(a), 0.5 + r * sin(a)))
            }
            poly(pts)
        }
        switch type {
        case .line, .dottedLine, .lineArrowEnd, .lineArrowStartEnd:
            p.move(to: .zero); p.addLine(to: CGPoint(x: 1, y: 1))
        case .rectangle, .custom:
            p.addRect(CGRect(x: 0, y: 0, width: 1, height: 1))
        case .roundRectangle:
            p.addRoundedRect(in: CGRect(x: 0, y: 0, width: 1, height: 1), cornerWidth: 0.15, cornerHeight: 0.15)
        case .circle:
            p.addEllipse(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        case .fan:
            // Quarter-circle sector pointing down, squeezed horizontally to fill the box.
            let squeeze = CGAffineTransform(translationX: 0.5, y: 0).scaledBy(x: 1 / 2.0.squareRoot(), y: 1).translatedBy(x: -0.5, y: 0)
            p.move(to: CGPoint(x: 0.5, y: 1))
            p.addArc(center: CGPoint(x: 0.5, y: 1), radius: 1, startAngle: -.pi * 0.75, endAngle: -.pi * 0.25, clockwise: false,
                     transform: squeeze)
            p.closeSubpath()
        case .triangle: poly([(0.5, 0), (1, 1), (0, 1)])
        case .rightTriangle: poly([(0, 0), (1, 1), (0, 1)])
        case .rhomboid: poly([(0.25, 0), (1, 0), (0.75, 1), (0, 1)])
        case .rhombus: poly([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)])
        case .trapezoid: poly([(0.25, 0), (0.75, 0), (1, 1), (0, 1)])
        case .polygon: regular(6, rotation: 0)
        case .star: regular(5, inner: 0.2)
        case .curveRhombus:
            p.move(to: CGPoint(x: 0.5, y: 0))
            p.addQuadCurve(to: CGPoint(x: 1, y: 0.5), control: CGPoint(x: 0.55, y: 0.45))
            p.addQuadCurve(to: CGPoint(x: 0.5, y: 1), control: CGPoint(x: 0.55, y: 0.55))
            p.addQuadCurve(to: CGPoint(x: 0, y: 0.5), control: CGPoint(x: 0.45, y: 0.55))
            p.addQuadCurve(to: CGPoint(x: 0.5, y: 0), control: CGPoint(x: 0.45, y: 0.45))
            p.closeSubpath()
        case .love:
            p.move(to: CGPoint(x: 0.5, y: 0.25))
            p.addCurve(to: CGPoint(x: 0, y: 0.3), control1: CGPoint(x: 0.4, y: 0), control2: CGPoint(x: 0, y: 0))
            p.addCurve(to: CGPoint(x: 0.5, y: 1), control1: CGPoint(x: 0, y: 0.6), control2: CGPoint(x: 0.35, y: 0.8))
            p.addCurve(to: CGPoint(x: 1, y: 0.3), control1: CGPoint(x: 0.65, y: 0.8), control2: CGPoint(x: 1, y: 0.6))
            p.addCurve(to: CGPoint(x: 0.5, y: 0.25), control1: CGPoint(x: 1, y: 0), control2: CGPoint(x: 0.6, y: 0))
            p.closeSubpath()
        case .brace:
            p.move(to: CGPoint(x: 0.8, y: 0))
            p.addQuadCurve(to: CGPoint(x: 0.5, y: 0.1), control: CGPoint(x: 0.5, y: 0))
            p.addLine(to: CGPoint(x: 0.5, y: 0.4))
            p.addQuadCurve(to: CGPoint(x: 0.2, y: 0.5), control: CGPoint(x: 0.5, y: 0.5))
            p.addQuadCurve(to: CGPoint(x: 0.5, y: 0.6), control: CGPoint(x: 0.5, y: 0.5))
            p.addLine(to: CGPoint(x: 0.5, y: 0.9))
            p.addQuadCurve(to: CGPoint(x: 0.8, y: 1), control: CGPoint(x: 0.5, y: 1))
        case .bracket:
            p.move(to: CGPoint(x: 0.8, y: 0))
            p.addLine(to: CGPoint(x: 0.3, y: 0))
            p.addLine(to: CGPoint(x: 0.3, y: 1))
            p.addLine(to: CGPoint(x: 0.8, y: 1))
        case .thunder:
            poly([(0.55, 0), (0.15, 0.55), (0.45, 0.55), (0.3, 1), (0.85, 0.4), (0.55, 0.4), (0.75, 0)])
        case .fire:
            p.move(to: CGPoint(x: 0.5, y: 1))
            p.addCurve(to: CGPoint(x: 0.15, y: 0.55), control1: CGPoint(x: 0.25, y: 1), control2: CGPoint(x: 0.1, y: 0.8))
            p.addCurve(to: CGPoint(x: 0.45, y: 0), control1: CGPoint(x: 0.2, y: 0.3), control2: CGPoint(x: 0.5, y: 0.25))
            p.addCurve(to: CGPoint(x: 0.7, y: 0.45), control1: CGPoint(x: 0.6, y: 0.2), control2: CGPoint(x: 0.6, y: 0.35))
            p.addCurve(to: CGPoint(x: 0.8, y: 0.25), control1: CGPoint(x: 0.75, y: 0.4), control2: CGPoint(x: 0.8, y: 0.3))
            p.addCurve(to: CGPoint(x: 0.5, y: 1), control1: CGPoint(x: 1, y: 0.6), control2: CGPoint(x: 0.8, y: 1))
            p.closeSubpath()
        case .moon:
            p.move(to: CGPoint(x: 0.6, y: 0))
            p.addCurve(to: CGPoint(x: 0.6, y: 1), control1: CGPoint(x: -0.15, y: 0), control2: CGPoint(x: -0.15, y: 1))
            p.addCurve(to: CGPoint(x: 0.6, y: 0), control1: CGPoint(x: 0.2, y: 0.8), control2: CGPoint(x: 0.2, y: 0.2))
            p.closeSubpath()
        case .sun:
            p.addEllipse(in: CGRect(x: 0.27, y: 0.27, width: 0.46, height: 0.46))
            for i in 0..<8 {
                let a = Double(i) * Double.pi / 4
                let l = CGPoint(x: 0.5 + 0.3 * cos(a - 0.12), y: 0.5 + 0.3 * sin(a - 0.12))
                let r = CGPoint(x: 0.5 + 0.3 * cos(a + 0.12), y: 0.5 + 0.3 * sin(a + 0.12))
                let tip = CGPoint(x: 0.5 + 0.5 * cos(a), y: 0.5 + 0.5 * sin(a))
                p.move(to: l); p.addLine(to: tip); p.addLine(to: r); p.closeSubpath()
            }
        case .cloud:
            let bumps: [(Double, Double, Double)] = [(0.3, 0.55, 0.22), (0.5, 0.4, 0.26), (0.72, 0.55, 0.22), (0.5, 0.68, 0.22), (0.22, 0.68, 0.18), (0.8, 0.7, 0.17)]
            for b in bumps { p.addEllipse(in: CGRect(x: b.0 - b.2, y: b.1 - b.2 * 0.8, width: b.2 * 2, height: b.2 * 1.6)) }
        case .smilingFace:
            p.addEllipse(in: CGRect(x: 0, y: 0, width: 1, height: 1))
            p.addEllipse(in: CGRect(x: 0.28, y: 0.3, width: 0.12, height: 0.14))
            p.addEllipse(in: CGRect(x: 0.6, y: 0.3, width: 0.12, height: 0.14))
            p.move(to: CGPoint(x: 0.27, y: 0.62))
            p.addQuadCurve(to: CGPoint(x: 0.73, y: 0.62), control: CGPoint(x: 0.5, y: 0.85))
        case .bomb:
            var pts: [(Double, Double)] = []
            for i in 0..<24 {
                let r = i % 2 == 0 ? 0.5 : 0.3 + 0.06 * Double(i % 3)
                let a = Double(i) * 2 * Double.pi / 24
                pts.append((0.5 + r * cos(a), 0.5 + r * sin(a)))
            }
            poly(pts)
        case .scroll:
            p.addRect(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
            p.addEllipse(in: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
            p.addEllipse(in: CGRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2))
        case .banner:
            poly([(0, 0.2), (0.15, 0.2), (0.15, 0), (0.85, 0), (0.85, 0.2), (1, 0.2), (0.9, 0.5), (1, 0.8), (0.85, 0.8), (0.85, 0.6), (0.15, 0.6), (0.15, 0.8), (0, 0.8), (0.1, 0.5)])
        case .medal:
            p.addEllipse(in: CGRect(x: 0.15, y: 0.3, width: 0.7, height: 0.7))
            poly([(0.25, 0), (0.45, 0), (0.55, 0.35), (0.35, 0.35)])
            poly([(0.55, 0), (0.75, 0), (0.65, 0.35), (0.45, 0.35)])
        case .arrowEnd: poly([(0, 0.3), (0.6, 0.3), (0.6, 0), (1, 0.5), (0.6, 1), (0.6, 0.7), (0, 0.7)])
        case .arrowStartEnd: poly([(0, 0.5), (0.25, 0), (0.25, 0.3), (0.75, 0.3), (0.75, 0), (1, 0.5), (0.75, 1), (0.75, 0.7), (0.25, 0.7), (0.25, 1)])
        case .arrowSwallow: poly([(0, 0.2), (0.6, 0.2), (0.6, 0), (1, 0.5), (0.6, 1), (0.6, 0.8), (0, 0.8), (0.2, 0.5)])
        case .curveArrow:
            p.move(to: CGPoint(x: 0, y: 1))
            p.addQuadCurve(to: CGPoint(x: 0.7, y: 0.25), control: CGPoint(x: 0.05, y: 0.25))
            p.addLine(to: CGPoint(x: 0.7, y: 0))
            p.addLine(to: CGPoint(x: 1, y: 0.4))
            p.addLine(to: CGPoint(x: 0.7, y: 0.8))
            p.addLine(to: CGPoint(x: 0.7, y: 0.55))
            p.addQuadCurve(to: CGPoint(x: 0.25, y: 1), control: CGPoint(x: 0.3, y: 0.55))
            p.closeSubpath()
        case .rotationArrow:
            p.addArc(center: CGPoint(x: 0.5, y: 0.5), radius: 0.4, startAngle: -.pi * 0.4, endAngle: .pi * 1.4, clockwise: false)
            p.addArc(center: CGPoint(x: 0.5, y: 0.5), radius: 0.25, startAngle: .pi * 1.4, endAngle: -.pi * 0.4, clockwise: true)
            p.closeSubpath()
            let a = -Double.pi * 0.4
            let tip = CGPoint(x: 0.5 + 0.325 * cos(a) + 0.12, y: 0.5 + 0.325 * sin(a) + 0.1)
            p.move(to: CGPoint(x: 0.5 + 0.5 * cos(a), y: 0.5 + 0.5 * sin(a)))
            p.addLine(to: tip)
            p.addLine(to: CGPoint(x: 0.5 + 0.15 * cos(a), y: 0.5 + 0.15 * sin(a)))
            p.closeSubpath()
        case .flag:
            p.addRect(CGRect(x: 0, y: 0, width: 0.06, height: 1))
            p.move(to: CGPoint(x: 0.06, y: 0.05))
            p.addQuadCurve(to: CGPoint(x: 1, y: 0.1), control: CGPoint(x: 0.5, y: -0.1))
            p.addLine(to: CGPoint(x: 1, y: 0.55))
            p.addQuadCurve(to: CGPoint(x: 0.06, y: 0.5), control: CGPoint(x: 0.5, y: 0.35))
            p.closeSubpath()
        case .rectangleMark: poly([(0, 0), (0.8, 0), (1, 0.5), (0.8, 1), (0, 1)])
        case .circleBubble:
            p.addEllipse(in: CGRect(x: 0, y: 0, width: 1, height: 0.8))
            poly([(0.25, 0.7), (0.15, 1), (0.42, 0.78)])
        case .rectangleBubble:
            poly([(0, 0), (1, 0), (1, 0.75), (0.4, 0.75), (0.2, 1), (0.25, 0.75), (0, 0.75)])
        case .bubble:
            p.addEllipse(in: CGRect(x: 0.1, y: 0, width: 0.9, height: 0.7))
            p.addEllipse(in: CGRect(x: 0.12, y: 0.72, width: 0.12, height: 0.1))
            p.addEllipse(in: CGRect(x: 0.02, y: 0.86, width: 0.08, height: 0.07))
        }
        return p
    }
}
