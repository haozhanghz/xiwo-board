import CoreGraphics
import Foundation

/// Steadies a stroke as it is written (防抖), so the small shakes of the hand and of the
/// tablet stay out of the line and handwriting comes out tidier (工整).
///
/// Every point moves onto a straight line fitted to the points around it, those within
/// three `sigma` along the stroke, weighted by a Gaussian of how far along they are.
/// Distance along the stroke rather than samples or time, so a slow stroke, with its many
/// close samples, is steadied as much as a fast one. Where the stroke turns sharply over a
/// short stretch, as at the corner of 口 or in the hook of 竖钩, it is cut in two and each
/// side is fitted on its own, so the turn stays sharp: the point at the turn takes the
/// middle of where the two sides put it. Next to an end or a turn the points lie on one
/// side only; a fitted line still runs through the middle of them, where an average would
/// pull the end in, so strokes keep their length and their corners.
///
/// The newest point only has points behind it, so the ink still reaches the pen. As the pen
/// moves on, the points behind it gain neighbours ahead and settle: `stable` counts those no
/// later point can move. The canvas draws all of `points` with every sample, so the end of
/// the line settles under the pen as it goes, and what is left when the pen lifts is what
/// was on screen.
public struct StrokeSmoother: Sendable {
    /// How far along the stroke the smoothing reaches, in slide units: the Gaussian's
    /// standard deviation. Zero leaves the points as they are.
    public let sigma: Double
    /// The points as written.
    public private(set) var raw: [StrokePoint] = []
    /// The steadied points, one for each of `raw`, with its pressure and width.
    public private(set) var points: [StrokePoint] = []
    /// How many of `points`, from the start, later points can no longer move.
    public private(set) var stable = 0

    /// The stroke turns sharply at a point that bends it by more than this, between the
    /// stretch of `span` before the point and the one after it.
    static let cornerAngle = 55 * Double.pi / 180

    /// Distance along the stroke to each raw point.
    private var arc: [Double] = []
    /// How much the stroke bends at each point; zero until it reaches `sigma` past the point.
    private var bend: [Double] = []
    /// How many bends, from the start, can no longer change.
    private var measured = 0
    private var corner: [Bool] = []
    /// How many corner marks, from the start, later points can no longer change.
    private var settledCorners = 0

    public init(sigma: Double) {
        self.sigma = sigma.isFinite ? max(0, sigma) : 0
    }

    /// The stretch either side of a point over which its bend is measured.
    private var span: Double { 2 * sigma }

    /// Adds the next point the pen reached. Returns the index of the first point whose
    /// steadied position may have changed.
    @discardableResult
    public mutating func append(_ p: StrokePoint) -> Int {
        let n = raw.count
        arc.append(n == 0 ? 0 : arc[n - 1] + hypot(p.x - raw[n - 1].x, p.y - raw[n - 1].y))
        raw.append(p)
        points.append(p)
        bend.append(0)
        corner.append(false)
        guard sigma > 0 else {
            stable = points.count
            return n
        }
        let end = arc[n]
        while measured <= n, end - arc[measured] >= span {
            bend[measured] = bend(at: measured)
            measured += 1
        }
        // Closer to the pen, a bend is measured over what there is so far, so a corner
        // the pen has just turned soon counts as one, and so does a short hook at the end.
        var j = measured
        while j <= n, end - arc[j] >= sigma {
            bend[j] = bend(at: j)
            j += 1
        }
        // A bend only counts as a corner where it is the sharpest within `span`, so it
        // can change until the bends that far ahead are known.
        for i in settledCorners...n { corner[i] = isCorner(i) }
        while end - arc[settledCorners] >= 2 * span { settledCorners += 1 }
        let from = stable
        for i in from...n { points[i] = steadied(i) }
        // A point's line reaches 3 sigma ahead, and a corner within that waits on the
        // bends two spans further.
        while end - arc[stable] >= 3 * sigma + 2 * span { stable += 1 }
        return from
    }

    /// The angle between the chord from `span` before point `i` and the chord to `span`
    /// after it, or to the newest point if that is nearer. Zero within `span` of the start,
    /// where the pen may still be settling on the surface, and within `sigma` of the end.
    private func bend(at i: Int) -> Double {
        let ahead = min(span, arc[arc.count - 1] - arc[i])
        guard arc[i] - arc[0] >= span, ahead >= sigma else { return 0 }
        let a = position(at: arc[i] - span, near: i), c = position(at: arc[i] + ahead, near: i)
        let p = raw[i]
        let ux = p.x - a.x, uy = p.y - a.y, vx = c.x - p.x, vy = c.y - p.y
        return atan2(abs(ux * vy - uy * vx), ux * vx + uy * vy)
    }

    /// The point `s` along the stroke as written, looked for outwards from point `i`.
    private func position(at s: Double, near i: Int) -> CGPoint {
        var j = i
        if s < arc[i] {
            while j > 0, arc[j - 1] > s { j -= 1 }
            guard j > 0 else { return raw[0].cgPoint }
            j -= 1
        } else {
            while j < arc.count - 1, arc[j + 1] < s { j += 1 }
            guard j < arc.count - 1 else { return raw[j].cgPoint }
        }
        let a = raw[j], b = raw[j + 1], len = arc[j + 1] - arc[j]
        let t = len > 0 ? (s - arc[j]) / len : 0
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Whether point `i` bends past `cornerAngle` and more sharply than every point within
    /// `span` of it (the first of equals).
    private func isCorner(_ i: Int) -> Bool {
        guard bend[i] > Self.cornerAngle else { return false }
        var j = i - 1
        while j >= 0, arc[i] - arc[j] <= span {
            if bend[j] >= bend[i] { return false }
            j -= 1
        }
        j = i + 1
        while j < arc.count, arc[j] - arc[i] <= span {
            if bend[j] > bend[i] { return false }
            j += 1
        }
        return true
    }

    /// Point `i` on the line fitted around it, stopping at corners.
    private func steadied(_ i: Int) -> StrokePoint {
        let reach = 3 * sigma
        var lo = i, hi = i
        while lo > 0, arc[i] - arc[lo - 1] <= reach {
            lo -= 1
            if corner[lo] { break }
        }
        while hi < arc.count - 1, arc[hi + 1] - arc[i] <= reach {
            hi += 1
            if corner[hi] { break }
        }
        var q = raw[i]
        let c: CGPoint
        if corner[i] {
            let a = fit(i, lo, i), b = fit(i, i, hi)
            c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        } else {
            c = fit(i, lo, hi)
        }
        q.x = c.x
        q.y = c.y
        return q
    }

    /// Where a straight line fitted to points `lo...hi`, weighted by how far along the
    /// stroke they are from point `i`, puts that point.
    private func fit(_ i: Int, _ lo: Int, _ hi: Int) -> CGPoint {
        let o = raw[i]
        guard hi > lo else { return o.cgPoint }
        let k = -1 / (2 * sigma * sigma)
        var sw = 0.0, swd = 0.0, swdd = 0.0, sx = 0.0, sy = 0.0, sxd = 0.0, syd = 0.0
        for j in lo...hi {
            // Each point stands for the stretch of stroke around it, so closely spaced
            // samples where the pen slowed down do not outweigh the rest.
            let share = ((j > lo ? arc[j] - arc[j - 1] : 0) + (j < hi ? arc[j + 1] - arc[j] : 0)) / 2
            let d = arc[j] - arc[i]
            let w = exp(k * d * d) * share
            let x = raw[j].x - o.x, y = raw[j].y - o.y
            sw += w; swd += w * d; swdd += w * d * d
            sx += w * x; sy += w * y; sxd += w * x * d; syd += w * y * d
        }
        guard sw > 0 else { return o.cgPoint }
        let det = sw * swdd - swd * swd
        // All the weight at one place along the stroke: nothing to fit a slope to.
        guard det > 1e-9 * sw * swdd else { return CGPoint(x: o.x + sx / sw, y: o.y + sy / sw) }
        return CGPoint(x: o.x + (swdd * sx - swd * sxd) / det, y: o.y + (swdd * sy - swd * syd) / det)
    }
}
