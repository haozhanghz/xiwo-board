import CoreGraphics
import Foundation

/// Gives the hard pen a nib (笔锋), the way a fountain pen writes: the line thins where
/// the pen moves fast and fills out where it slows down or presses harder, and a stroke
/// the pen leaves while still moving ends in a point, as a 撇 or a 钩 does when it is
/// flicked off the paper.
///
/// The canvas hands it each point it adds to the stroke and stores the answer as the
/// point's `widthScale`. Speeds are taken on screen, in view points, so the line looks
/// the same at any zoom; times are `NSEvent` timestamps, in seconds.
///
/// The width follows a smoothed speed and is smoothed once more itself, so it swells and
/// thins over a few samples instead of with the jitter between two of them. Whether a
/// stroke ends in a point is only known when the pen lifts, so `taper` narrows the end
/// then, on the points already written.
public struct PenNib: Sendable {
    /// Width with the pen at rest, and at `fastSpeed` and faster.
    static let slowScale = 1.18, fastScale = 0.72
    /// View points per millisecond: the line starts to thin above `slowSpeed` and is
    /// thinnest from `fastSpeed` on.
    static let slowSpeed = 0.05, fastSpeed = 1.0
    /// Milliseconds the measured speed, and then the width, take to follow the pen.
    static let speedTime = 18.0, widthTime = 10.0
    /// The end tapers when the pen covered more than `liftSpeed` view points per
    /// millisecond over its last `liftWindow` milliseconds: over the distance `taperTime`
    /// milliseconds of the speed beyond that would cover, at most `taperWidths` pen widths,
    /// down to `endScale` of the width.
    static let liftWindow = 12.0, liftSpeed = 0.2, taperTime = 55.0, taperWidths = 7.0, endScale = 0.1
    /// A pen that rests this many milliseconds before it lifts had stopped.
    static let restTime = 25.0

    /// The pen's width in slide units.
    public let width: Double
    /// View points per slide unit.
    public let scale: Double

    private var speed = 0.0
    private var current: Double?
    /// The last few points and their times in milliseconds, for the speed the pen lifts at.
    private var recent: [(point: CGPoint, time: Double)] = []

    public init(width: Double, scale: Double) {
        self.width = width
        self.scale = max(scale, 1e-6)
    }

    /// The width for a point the pen reached at `time`, as a fraction of the pen's width.
    /// `pressure` is nil for a mouse or trackpad.
    public mutating func widthScale(at p: CGPoint, time: TimeInterval, pressure: Double?) -> Double {
        let ms = time * 1000
        var dt = 0.0
        if let last = recent.last {
            dt = max(0.5, ms - last.time)
            let v = hypot(p.x - last.point.x, p.y - last.point.y) * scale / dt
            speed += (v - speed) * (1 - exp(-dt / Self.speedTime))
        }
        recent.append((p, ms))
        if recent.count > 16 { recent.removeFirst() }
        var target = Self.slowScale + (Self.fastScale - Self.slowScale) * smoothstep(Self.slowSpeed, Self.fastSpeed, speed)
        if let pressure { target *= 0.7 + 0.6 * min(1, max(0, pressure)) }
        let w = current.map { $0 + (target - $0) * (1 - exp(-dt / Self.widthTime)) } ?? target
        current = w
        return Self.rounded(w)
    }

    /// The pen lifted at `time`. If it was still moving, the end of `points`, the stroke as
    /// written, narrows to a point.
    public func taper(_ points: inout [StrokePoint], liftedAt time: TimeInterval) {
        guard points.count > 2, let last = recent.last, time * 1000 - last.time < Self.restTime else { return }
        // How fast the pen went over its last steps: every step within the window, and at
        // least the last one, for mice and trackpads that report less often.
        var covered = 0.0, span = 0.0
        for i in stride(from: recent.count - 1, to: 0, by: -1) {
            let a = recent[i - 1], b = recent[i]
            if span > 0, last.time - a.time > Self.liftWindow { break }
            covered += hypot(b.point.x - a.point.x, b.point.y - a.point.y)
            span = last.time - a.time
        }
        guard span > 0, span < 2 * Self.restTime else { return }
        let speed = covered * scale / span
        var total = 0.0
        for i in 1..<points.count { total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y) }
        // A short flick keeps its start.
        let length = min(Self.taperWidths * width, max(0, speed - Self.liftSpeed) * Self.taperTime / scale, 0.7 * total)
        guard length > 0 else { return }
        var d = 0.0
        for i in stride(from: points.count - 1, through: 0, by: -1) {
            if i < points.count - 1 { d += hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y) }
            guard d < length else { break }
            let k = Self.endScale + (1 - Self.endScale) * smoothstep(0, 1, d / length)
            points[i].widthScale = Self.rounded((points[i].widthScale ?? 1) * k)
        }
    }

    /// Three decimals are finer than a pixel at any pen width and keep files small.
    private static func rounded(_ w: Double) -> Double { (w * 1000).rounded() / 1000 }

    private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
