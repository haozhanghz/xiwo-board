import CoreGraphics
import Foundation

extension BoardElement {
    /// Creates an ink element from points in slide coordinates.
    public static func stroke(points: [StrokePoint], color: RGBA, width: Double, kind: PenKind) -> BoardElement {
        let pad = Stroke(points: points, color: color, width: width, kind: kind).reach + 1
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = (xs.min() ?? 0) - pad, minY = (ys.min() ?? 0) - pad
        let maxX = (xs.max() ?? 0) + pad, maxY = (ys.max() ?? 0) + pad
        let local = points.map { $0.offsetBy(dx: -minX, dy: -minY) }
        return BoardElement(frame: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                            content: .stroke(Stroke(points: local, color: color, width: width, kind: kind)))
    }

    /// Stroke points in slide coordinates (empty for non-ink elements).
    public var absoluteStrokePoints: [StrokePoint] {
        guard case .stroke(let s) = content else { return [] }
        return s.points.map { $0.offsetBy(dx: frame.minX, dy: frame.minY) }
    }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    public mutating func move(dx: Double, dy: Double) {
        frame = frame.offsetBy(dx: dx, dy: dy)
        if case .group(var children) = content {
            for i in children.indices { children[i].move(dx: dx, dy: dy) }
            content = .group(children)
        }
    }

    /// Changes the frame, scaling ink and group children proportionally.
    public mutating func setFrame(_ newFrame: CGRect) {
        let old = frame
        var nf = newFrame.standardized
        if nf.width < 1 { nf.size.width = 1 }
        if nf.height < 1 { nf.size.height = 1 }
        let sx = old.width > 0 ? nf.width / old.width : 1
        let sy = old.height > 0 ? nf.height / old.height : 1
        switch content {
        case .stroke(var s):
            s.points = s.points.map { p in
                var q = p
                q.x *= sx; q.y *= sy
                return q
            }
            content = .stroke(s)
        case .group(var children):
            for i in children.indices {
                let f = children[i].frame
                children[i].setFrame(CGRect(x: nf.minX + (f.minX - old.minX) * sx, y: nf.minY + (f.minY - old.minY) * sy,
                                            width: f.width * sx, height: f.height * sy))
            }
            content = .group(children)
        case .text(var t) where abs(sy - 1) > 0.001 && abs(sx - sy) < 0.001:
            // Uniform corner-drag on text scales the type, like a picture.
            t.fontSize = max(6, t.fontSize * sy)
            content = .text(t)
        default:
            break
        }
        frame = nf
    }

    /// Maps a slide point into the element's unrotated frame space.
    public func unrotate(_ p: CGPoint) -> CGPoint {
        guard rotation != 0 else { return p }
        let a = -rotation * .pi / 180
        let c = center
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }

    /// Hit test in slide coordinates. Ink is hit along its line; other elements by their frame.
    public func hitTest(_ p: CGPoint, tolerance: Double = 6) -> Bool {
        let q = unrotate(p)
        switch content {
        case .stroke(let s):
            guard frame.insetBy(dx: -tolerance, dy: -tolerance).contains(q) else { return false }
            let pts = s.points.map { CGPoint(x: $0.x + frame.minX, y: $0.y + frame.minY) }
            let limit = s.reach + tolerance
            if pts.count == 1 { return hypot(pts[0].x - q.x, pts[0].y - q.y) <= limit }
            for i in 1..<max(pts.count, 1) where Geometry.distance(q, segment: pts[i - 1], pts[i]) <= limit { return true }
            return false
        case .shape(let s) where s.type.isLine:
            let (a, b) = s.lineEnds(in: frame)
            return Geometry.distance(q, segment: a, b) <= s.style.lineWidth / 2 + tolerance
        default:
            return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(q)
        }
    }

    /// Whether anything of the element lies within `tolerance` of the path from `a` to
    /// `b`, such as an eraser moving between two pointer samples.
    public func hitTest(from a: CGPoint, to b: CGPoint, tolerance: Double = 6) -> Bool {
        guard a != b else { return hitTest(a, tolerance: tolerance) }
        let qa = unrotate(a), qb = unrotate(b)
        switch content {
        case .stroke(let s):
            let limit = s.reach + tolerance
            guard Geometry.bounds(qa, qb).insetBy(dx: -limit, dy: -limit).intersects(frame) else { return false }
            let pts = s.points.map { CGPoint(x: $0.x + frame.minX, y: $0.y + frame.minY) }
            if pts.count == 1 { return Geometry.distance(pts[0], segment: qa, qb) <= limit }
            for i in 1..<max(pts.count, 1) where Geometry.distance(segment: pts[i - 1], pts[i], qa, qb) <= limit { return true }
            return false
        case .shape(let s) where s.type.isLine:
            let (p, q) = s.lineEnds(in: frame)
            return Geometry.distance(segment: p, q, qa, qb) <= s.style.lineWidth / 2 + tolerance
        default:
            return Geometry.segment(qa, qb, meets: frame.insetBy(dx: -tolerance, dy: -tolerance))
        }
    }

    /// Axis-aligned bounds of the rotated frame.
    public var boundingBox: CGRect {
        guard rotation != 0 else { return frame }
        let c = center
        var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rotation * .pi / 180).translatedBy(x: -c.x, y: -c.y)
        return CGPath(rect: frame, transform: &t).boundingBoxOfPath
    }

    /// Removes the parts of an ink element under a circular eraser.
    /// Returns the surviving pieces (empty if fully erased, `[self]` if untouched).
    public func erasing(center c: CGPoint, radius r: Double) -> [BoardElement] {
        erasing(from: c, to: c, radius: r)
    }

    /// Removes the parts of an ink element that a circular eraser passes over while it
    /// moves from `start` to `end`, so a quick swipe also clears the ink between two
    /// pointer samples. Returns the surviving pieces (empty if fully erased, `[self]`
    /// if untouched).
    public func erasing(from start: CGPoint, to end: CGPoint, radius r: Double) -> [BoardElement] {
        guard case .stroke(let s) = content else { return [self] }
        let a = unrotate(start), b = unrotate(end)
        let reach = max(0, r) + s.reach
        guard Geometry.bounds(a, b).insetBy(dx: -reach, dy: -reach).intersects(frame) else { return [self] }
        let pts = absoluteStrokePoints
        guard pts.count > 1 else {
            return pts.first.map { Geometry.distance($0.cgPoint, segment: a, b) <= reach ? [] : [self] } ?? [self]
        }
        var pieces: [[StrokePoint]] = []
        var piece: [StrokePoint] = []
        var touched = false

        func interpolate(_ a: StrokePoint, _ b: StrokePoint, _ t: Double) -> StrokePoint {
            StrokePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                        pressure: a.pressure + (b.pressure - a.pressure) * t,
                        widthScale: a.widthScale.map { $0 + ((b.widthScale ?? $0) - $0) * t })
        }
        func append(_ a: StrokePoint, _ b: StrokePoint) {
            if piece.last != a { piece.append(a) }
            if piece.last != b { piece.append(b) }
        }
        func finishPiece() {
            if !piece.isEmpty { pieces.append(piece); piece = [] }
        }

        // Clip segments against the area the eraser swept. Simplified ink often has
        // only two distant points, so testing just the stored points misses the line.
        for i in 1..<pts.count {
            let p = pts[i - 1], q = pts[i]
            if p.x == q.x && p.y == q.y {
                if Geometry.distance(p.cgPoint, segment: a, b) <= reach { touched = true; finishPiece() }
                else { append(p, q) }
                continue
            }
            guard let (enter, exit) = Geometry.span(of: p.cgPoint, q.cgPoint, insideCapsule: a, b, radius: reach) else {
                append(p, q); continue
            }
            touched = true
            if enter > 0 { append(p, interpolate(p, q, enter)) }
            finishPiece()
            if exit < 1 { append(interpolate(p, q, exit), q) }
        }
        finishPiece()
        guard touched else { return [self] }
        return pieces.map { points in
            let fragment = BoardElement.stroke(points: points, color: s.color, width: s.width, kind: s.kind)
            var e = self
            e.frame = fragment.frame
            e.content = fragment.content
            // A fragment rotates around its own centre. Move that centre to its
            // rotated position so splitting a rotated stroke keeps the ink still.
            if rotation != 0 {
                let angle = rotation * .pi / 180
                let dx = e.center.x - center.x, dy = e.center.y - center.y
                e.move(dx: dx * cos(angle) - dy * sin(angle) - dx,
                       dy: dx * sin(angle) + dy * cos(angle) - dy)
            }
            e.id = BoardElement.newID()
            return e
        }
    }

    /// The children of a group as elements of their own, each carrying the group's
    /// rotation, opacity and classroom settings so it looks and behaves as it did inside.
    public func ungrouped() -> [BoardElement] {
        guard case .group(let children) = content else { return [self] }
        let angle = rotation * .pi / 180
        return children.map { child in
            var e = child
            if rotation != 0 {
                // Children keep their frames in the group's unrotated space: turn each
                // centre about the group's centre and add the group's angle.
                let dx = e.center.x - center.x, dy = e.center.y - center.y
                e.move(dx: dx * cos(angle) - dy * sin(angle) - dx, dy: dx * sin(angle) + dy * cos(angle) - dy)
                let turned = (e.rotation + rotation).truncatingRemainder(dividingBy: 360)
                e.rotation = abs(turned) < 1e-9 ? 0 : turned
            }
            e.opacity *= opacity
            e.locked = e.locked || locked
            e.masked = e.masked || masked
            e.cloneOnDrag = e.cloneOnDrag || cloneOnDrag
            if e.hyperlink == nil { e.hyperlink = hyperlink }
            return e
        }
    }

    /// Height a text box needs to show every line of its text at its width (nil for
    /// anything but text). Text is drawn 6 points in from the sides and 4 from the top.
    public var fittedTextHeight: Double? {
        guard case .text(let t) = content else { return nil }
        return max(SlideRenderer.textHeight(t, width: frame.width - 12) + 8, 20)
    }

    /// Re-fits a text box after its text, style or width changed. A box that fitted its
    /// old text keeps fitting the new one, growing or shrinking with it; one made taller
    /// by hand keeps its extra room. Either way no line ends up outside the box.
    public mutating func refitText(was old: BoardElement) {
        guard let need = fittedTextHeight else { return }
        let snug = old.fittedTextHeight.map { old.frame.height <= $0 + 1 } ?? true
        frame.size.height = snug ? need : max(frame.height, need)
    }

    /// Grows a text box so none of its lines fall outside it.
    public mutating func growToFitText() {
        if let need = fittedTextHeight, frame.height < need { frame.size.height = need }
    }

    /// Bounding union of several elements, used for multi-selection.
    public static func union(_ elements: [BoardElement]) -> CGRect? {
        guard var r = elements.first?.boundingBox else { return nil }
        for e in elements.dropFirst() { r = r.union(e.boundingBox) }
        return r
    }

    /// Wraps elements in a group whose frame is their union.
    public static func group(_ elements: [BoardElement]) -> BoardElement? {
        guard elements.count > 1, let r = union(elements) else { return nil }
        return BoardElement(frame: r, content: .group(elements))
    }
}

public enum Geometry {
    public static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Shortest distance between the segments `a`–`b` and `c`–`d`.
    public static func distance(segment a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Double {
        func side(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Double { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        let ab1 = side(a, b, c), ab2 = side(a, b, d), cd1 = side(c, d, a), cd2 = side(c, d, b)
        if ((ab1 > 0 && ab2 < 0) || (ab1 < 0 && ab2 > 0)) && ((cd1 > 0 && cd2 < 0) || (cd1 < 0 && cd2 > 0)) { return 0 }
        return min(distance(a, segment: c, d), distance(b, segment: c, d), distance(c, segment: a, b), distance(d, segment: a, b))
    }

    /// The rectangle with `a` and `b` at opposite corners.
    public static func bounds(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Whether the segment `a`–`b` touches the rectangle `r`.
    public static func segment(_ a: CGPoint, _ b: CGPoint, meets r: CGRect) -> Bool {
        var lo = 0.0, hi = 1.0
        let axes: [(Double, Double, Double, Double)] = [(a.x, b.x - a.x, r.minX, r.maxX), (a.y, b.y - a.y, r.minY, r.maxY)]
        for (start, delta, low, high) in axes {
            if delta == 0 {
                if start < low || start > high { return false }
                continue
            }
            let t0 = (low - start) / delta, t1 = (high - start) / delta
            lo = max(lo, min(t0, t1)); hi = min(hi, max(t0, t1))
            if lo > hi { return false }
        }
        return true
    }

    /// The part of the segment `p`–`q`, as fractions of its length, that runs inside
    /// the capsule a circle of radius `r` sweeps moving from `a` to `b`; nil if none does.
    public static func span(of p: CGPoint, _ q: CGPoint, insideCapsule a: CGPoint, _ b: CGPoint,
                            radius r: Double) -> (Double, Double)? {
        let dx = Double(q.x - p.x), dy = Double(q.y - p.y)
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return nil }
        var lo = Double.infinity, hi = -Double.infinity
        func take(_ span: (Double, Double)?) {
            guard let span else { return }
            lo = min(lo, span.0); hi = max(hi, span.1)
        }
        // The circle at either end of the sweep.
        func disc(_ c: CGPoint) -> (Double, Double)? {
            let fx = Double(p.x - c.x), fy = Double(p.y - c.y)
            let half = fx * dx + fy * dy
            let depth = half * half - length2 * (fx * fx + fy * fy - r * r)
            guard depth > 0 else { return nil }
            let root = depth.squareRoot()
            return ((-half - root) / length2, (-half + root) / length2)
        }
        // The band between them: along the sweep from 0 to its length, across it within r.
        func band() -> (Double, Double)? {
            let ex = Double(b.x - a.x), ey = Double(b.y - a.y)
            let length = (ex * ex + ey * ey).squareRoot()
            guard length > 0 else { return nil }
            let ux = ex / length, uy = ey / length
            let px = Double(p.x - a.x), py = Double(p.y - a.y)
            let along: (Double, Double, Double, Double) = (px * ux + py * uy, dx * ux + dy * uy, 0, length)
            let across: (Double, Double, Double, Double) = (py * ux - px * uy, dy * ux - dx * uy, -r, r)
            var lo = -Double.infinity, hi = Double.infinity
            for (start, delta, low, high) in [along, across] {
                if delta == 0 {
                    guard start > low && start < high else { return nil }
                    continue
                }
                let t0 = (low - start) / delta, t1 = (high - start) / delta
                lo = max(lo, min(t0, t1)); hi = min(hi, max(t0, t1))
            }
            return lo < hi ? (lo, hi) : nil
        }
        take(disc(a))
        if a != b {
            take(disc(b))
            take(band())
        }
        // The capsule is convex, so the pieces join into one stretch of the segment.
        let enter = max(0, lo), exit = min(1, hi)
        return enter < exit ? (enter, exit) : nil
    }

    /// Ramer–Douglas–Peucker simplification, keeping pressure of retained points. Where
    /// points carry a nib's width (`widthScale`, a fraction of `width`), a point also stays
    /// if dropping it would move the edge of the line by more than `tolerance`.
    public static func simplify(_ pts: [StrokePoint], tolerance: Double, width: Double = 0) -> [StrokePoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            var maxD = 0.0, idx = s
            let a = pts[s], b = pts[e]
            let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
            for i in (s + 1)..<e {
                var d = distance(pts[i].cgPoint, segment: a.cgPoint, b.cgPoint)
                if let w = pts[i].widthScale, let wa = a.widthScale, let wb = b.widthScale {
                    // Without the point, the width would run straight from one kept end to the other.
                    let t = len2 > 0 ? max(0, min(1, ((pts[i].x - a.x) * dx + (pts[i].y - a.y) * dy) / len2)) : 0
                    d = max(d, abs(w - (wa + (wb - wa) * t)) * width / 2)
                }
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance { keep[idx] = true; stack.append((s, idx)); stack.append((idx, e)) }
        }
        return pts.enumerated().filter { keep[$0.offset] }.map(\.element)
    }
}
