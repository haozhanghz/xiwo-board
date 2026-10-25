import CoreGraphics
import Foundation

/// One straight piece of a stroke as the GPU draws it: everything within `width / 2`
/// of the line from `a` to `b`, so each end is round unless it is marked square.
/// A dot is a piece whose ends coincide.
///
/// Under a pen with a nib the width at `b` can differ: the piece is then a disc of
/// `width` at `a` and one of `endWidth` at `b` with straight sides tangent to both.
public struct InkSegment: Equatable, Sendable {
    public var a: CGPoint
    public var b: CGPoint
    public var width: Double
    public var endWidth: Double
    /// The end extends `width / 2` past `a` (or `b`) and is cut off square there,
    /// like Core Graphics' square line cap.
    public var squareStart: Bool
    public var squareEnd: Bool

    public init(a: CGPoint, b: CGPoint, width: Double, endWidth: Double? = nil, squareStart: Bool = false, squareEnd: Bool = false) {
        self.a = a; self.b = b; self.width = width; self.endWidth = endWidth ?? width
        self.squareStart = squareStart; self.squareEnd = squareEnd
    }

    /// Adds the piece's round ends and the area between them to `path` as one closed
    /// outline, wound the same way as every other piece's, so filling the path with the
    /// non-zero rule paints all of them at once, overlaps included.
    public func addOutline(to path: CGMutablePath) {
        let ra = width / 2, rb = endWidth / 2
        let dx = b.x - a.x, dy = b.y - a.y
        let d = hypot(dx, dy)
        guard d > abs(ra - rb) else {
            // One end's disc holds the other's.
            let (c, r) = ra >= rb ? (a, ra) : (b, rb)
            path.move(to: CGPoint(x: c.x + r, y: c.y))
            path.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi, clockwise: false)
            path.addArc(center: c, radius: r, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
            return
        }
        // The sides touch each disc at ±phi from the direction a → b.
        let theta = atan2(dy, dx), phi = acos((ra - rb) / d)
        path.move(to: CGPoint(x: a.x + ra * cos(theta + phi), y: a.y + ra * sin(theta + phi)))
        path.addArc(center: a, radius: ra, startAngle: theta + phi, endAngle: theta - phi, clockwise: false)
        path.addArc(center: b, radius: rb, startAngle: theta - phi, endAngle: theta + phi, clockwise: false)
        path.closeSubpath()
    }
}

/// Breaks the stroke being written into the pieces that draw the same line as
/// `SlideRenderer.drawStroke`, one point at a time.
///
/// The pen and the highlighter follow `SlideRenderer.smoothPath`: quadratic curves
/// through the midpoints, flattened into short straight pieces. Round joins come
/// from each piece's round ends; the highlighter's two ends are square, as its line
/// cap is. A pen with a nib carries its points' widths along the same curves, and
/// `SlideRenderer` fills these very pieces for it. The brush draws one piece per pair
/// of points with the width its pressure gives, smoothed the way `drawBrush` smooths it.
///
/// A new point can only change the end of the line, so the pieces before it are
/// `fixed` and only `tail` is redone. Each point costs the same however long the
/// stroke is.
public struct InkTessellator: Sendable {
    public let width: Double
    public let kind: PenKind
    /// How far, in slide units, a straight piece may stray from the curve it stands for.
    public let tolerance: Double

    public private(set) var points: [StrokePoint] = []
    /// Pieces later points cannot change.
    public private(set) var fixed: [InkSegment] = []
    /// The end of the line, redone with every point.
    public private(set) var tail: [InkSegment] = []
    /// Brush widths after smoothing; the last one is still the raw width.
    private var widths: [Double] = []

    public init(width: Double, kind: PenKind, tolerance: Double) {
        self.width = width
        self.kind = kind
        self.tolerance = max(tolerance, 1e-4)
    }

    /// Every piece of `stroke`, drawn at `origin` (an element's frame origin).
    public static func segments(of stroke: Stroke, origin: CGPoint = .zero, tolerance: Double) -> [InkSegment] {
        var t = InkTessellator(width: stroke.width, kind: stroke.kind, tolerance: tolerance)
        for p in stroke.points { t.append(p.offsetBy(dx: origin.x, dy: origin.y)) }
        return t.fixed + t.tail
    }

    public var segmentCount: Int { fixed.count + tail.count }

    public mutating func append(_ p: StrokePoint) {
        points.append(p)
        if kind == .brush { appendBrush() } else { appendSmoothed() }
    }

    private mutating func appendSmoothed() {
        let n = points.count
        let square = kind == .highlighter
        let last = points[n - 1].cgPoint
        // Only the pen has a nib.
        func w(_ i: Int) -> Double { kind == .pen ? width * (points[i].widthScale ?? 1) : width }
        switch n {
        case 1:
            tail = [InkSegment(a: last, b: last, width: w(0))]
        case 2:
            tail = [InkSegment(a: points[0].cgPoint, b: last, width: w(0), endWidth: w(1), squareStart: square, squareEnd: square)]
        default:
            // The curve that ended with a straight line to the previous point now bends
            // through it: control at that point, ending halfway to the new one.
            let c = points[n - 2].cgPoint
            let start = n == 3 ? points[0].cgPoint : Self.mid(points[n - 3].cgPoint, c)
            let end = Self.mid(c, last)
            let startWidth = n == 3 ? w(0) : (w(n - 3) + w(n - 2)) / 2, endWidth = (w(n - 2) + w(n - 1)) / 2
            if n == 3, square { fixed.append(squareStart(at: start, toward: c, or: end)) }
            flatten(start, c, end, widths: startWidth, w(n - 2), endWidth)
            tail = [InkSegment(a: end, b: last, width: endWidth, endWidth: w(n - 1), squareEnd: square)]
        }
    }

    /// Core Graphics squares off the start along the curve's tangent, which points at the
    /// control point; the first straight piece of the curve runs a little off that, enough
    /// to turn the corners of a wide highlighter by a pixel. A sliver of a piece along the
    /// tangent carries the square end instead.
    private func squareStart(at s: CGPoint, toward c: CGPoint, or e: CGPoint) -> InkSegment {
        var dx = c.x - s.x, dy = c.y - s.y
        if hypot(dx, dy) < 1e-9 { dx = e.x - s.x; dy = e.y - s.y }
        let len = hypot(dx, dy)
        guard len > 1e-9 else { return InkSegment(a: s, b: s, width: width, squareStart: true) }
        let b = CGPoint(x: s.x + dx / len * tolerance, y: s.y + dy / len * tolerance)
        return InkSegment(a: s, b: b, width: width, squareStart: true)
    }

    /// Pieces along the quadratic from `s` to `e` with control `c`, the width following
    /// the same curve from `ws` through `wc` to `we`.
    private mutating func flatten(_ s: CGPoint, _ c: CGPoint, _ e: CGPoint, widths ws: Double, _ wc: Double, _ we: Double) {
        // A quadratic strays at most |s - 2c + e| / 4 from its chord; k pieces cut that by k².
        // The edge strays by half as much as the width does.
        let dx = s.x - 2 * c.x + e.x, dy = s.y - 2 * c.y + e.y
        let bend = max(hypot(dx, dy), abs(ws - 2 * wc + we) / 2)
        let k = max(1, min(32, Int((sqrt(bend / (4 * tolerance))).rounded(.up))))
        var prev = s, prevWidth = ws
        for i in 1...k {
            let t = Double(i) / Double(k), u = 1 - t
            let p = CGPoint(x: u * u * s.x + 2 * u * t * c.x + t * t * e.x, y: u * u * s.y + 2 * u * t * c.y + t * t * e.y)
            let w = u * u * ws + 2 * u * t * wc + t * t * we
            fixed.append(InkSegment(a: prev, b: p, width: prevWidth, endWidth: w))
            prev = p; prevWidth = w
        }
    }

    private mutating func appendBrush() {
        func raw(_ p: StrokePoint) -> Double { width * (0.3 + 0.7 * max(0.05, min(1, p.pressure))) }
        let n = points.count
        widths.append(raw(points[n - 1]))
        let last = points[n - 1].cgPoint
        guard n > 1 else {
            tail = [InkSegment(a: last, b: last, width: widths[0])]
            return
        }
        if n > 2 {
            // `drawBrush` smooths in place, so each width averages the already smoothed
            // one before it. The previous point now has a neighbour on both sides.
            widths[n - 2] = (widths[n - 3] + 2 * widths[n - 2] + widths[n - 1]) / 4
            fixed.append(InkSegment(a: points[n - 3].cgPoint, b: points[n - 2].cgPoint, width: (widths[n - 3] + widths[n - 2]) / 2))
        }
        tail = [InkSegment(a: points[n - 2].cgPoint, b: last, width: (widths[n - 2] + widths[n - 1]) / 2)]
    }

    private static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
}
