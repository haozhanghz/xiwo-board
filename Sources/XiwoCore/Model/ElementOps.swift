import CoreGraphics
import Foundation

extension BoardElement {
    /// Creates an ink element from points in slide coordinates.
    public static func stroke(points: [StrokePoint], color: RGBA, width: Double, kind: PenKind) -> BoardElement {
        let pad = width / 2 + 1
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = (xs.min() ?? 0) - pad, minY = (ys.min() ?? 0) - pad
        let maxX = (xs.max() ?? 0) + pad, maxY = (ys.max() ?? 0) + pad
        let local = points.map { StrokePoint(x: $0.x - minX, y: $0.y - minY, pressure: $0.pressure) }
        return BoardElement(frame: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                            content: .stroke(Stroke(points: local, color: color, width: width, kind: kind)))
    }

    /// Stroke points in slide coordinates (empty for non-ink elements).
    public var absoluteStrokePoints: [StrokePoint] {
        guard case .stroke(let s) = content else { return [] }
        return s.points.map { StrokePoint(x: $0.x + frame.minX, y: $0.y + frame.minY, pressure: $0.pressure) }
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
            s.points = s.points.map { StrokePoint(x: $0.x * sx, y: $0.y * sy, pressure: $0.pressure) }
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
            let limit = s.width / 2 + tolerance
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
        guard case .stroke(let s) = content else { return [self] }
        guard frame.insetBy(dx: -r, dy: -r).contains(c) else { return [self] }
        let pts = absoluteStrokePoints
        let reach = r + s.width / 2
        var pieces: [[StrokePoint]] = [[]]
        var touched = false
        for p in pts {
            if hypot(p.x - c.x, p.y - c.y) <= reach {
                touched = true
                if !(pieces.last?.isEmpty ?? true) { pieces.append([]) }
            } else {
                pieces[pieces.count - 1].append(p)
            }
        }
        guard touched else { return [self] }
        return pieces.filter { $0.count >= 2 }.map {
            var e = BoardElement.stroke(points: $0, color: s.color, width: s.width, kind: s.kind)
            e.opacity = opacity
            return e
        }
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

    /// Ramer–Douglas–Peucker simplification, keeping pressure of retained points.
    public static func simplify(_ pts: [StrokePoint], tolerance: Double) -> [StrokePoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            var maxD = 0.0, idx = s
            for i in (s + 1)..<e {
                let d = distance(pts[i].cgPoint, segment: pts[s].cgPoint, pts[e].cgPoint)
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance { keep[idx] = true; stack.append((s, idx)); stack.append((idx, e)) }
        }
        return pts.enumerated().filter { keep[$0.offset] }.map(\.element)
    }
}
