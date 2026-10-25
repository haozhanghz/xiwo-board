import CoreGraphics
import Foundation

/// One straight piece of a stroke as the GPU draws it: everything within `width / 2`
/// of the line from `a` to `b`, so each end is round unless it is marked square.
/// A dot is a piece whose ends coincide.
public struct InkSegment: Equatable, Sendable {
    public var a: CGPoint
    public var b: CGPoint
    public var width: Double
    /// The end extends `width / 2` past `a` (or `b`) and is cut off square there,
    /// like Core Graphics' square line cap.
    public var squareStart: Bool
    public var squareEnd: Bool

    public init(a: CGPoint, b: CGPoint, width: Double, squareStart: Bool = false, squareEnd: Bool = false) {
        self.a = a; self.b = b; self.width = width; self.squareStart = squareStart; self.squareEnd = squareEnd
    }
}

/// Breaks the stroke being written into the pieces that draw the same line as
/// `SlideRenderer.drawStroke`, one point at a time.
///
/// The pen and the highlighter follow `SlideRenderer.smoothPath`: quadratic curves
/// through the midpoints, flattened into short straight pieces. Round joins come
/// from each piece's round ends; the highlighter's two ends are square, as its line
/// cap is. The brush draws one piece per pair of points with the width its pressure
/// gives, smoothed the way `drawBrush` smooths it.
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
        for p in stroke.points { t.append(StrokePoint(x: p.x + origin.x, y: p.y + origin.y, pressure: p.pressure)) }
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
        switch n {
        case 1:
            tail = [InkSegment(a: last, b: last, width: width)]
        case 2:
            tail = [InkSegment(a: points[0].cgPoint, b: last, width: width, squareStart: square, squareEnd: square)]
        default:
            // The curve that ended with a straight line to the previous point now bends
            // through it: control at that point, ending halfway to the new one.
            let c = points[n - 2].cgPoint
            let start = n == 3 ? points[0].cgPoint : Self.mid(points[n - 3].cgPoint, c)
            let end = Self.mid(c, last)
            if n == 3, square { fixed.append(squareStart(at: start, toward: c, or: end)) }
            flatten(start, c, end)
            tail = [InkSegment(a: end, b: last, width: width, squareEnd: square)]
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

    private mutating func flatten(_ s: CGPoint, _ c: CGPoint, _ e: CGPoint) {
        // A quadratic strays at most |s - 2c + e| / 4 from its chord; k pieces cut that by k².
        let dx = s.x - 2 * c.x + e.x, dy = s.y - 2 * c.y + e.y
        let k = max(1, min(32, Int((sqrt(hypot(dx, dy) / (4 * tolerance))).rounded(.up))))
        var prev = s
        for i in 1...k {
            let t = Double(i) / Double(k), u = 1 - t
            let p = CGPoint(x: u * u * s.x + 2 * u * t * c.x + t * t * e.x, y: u * u * s.y + 2 * u * t * c.y + t * t * e.y)
            fixed.append(InkSegment(a: prev, b: p, width: width))
            prev = p
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
