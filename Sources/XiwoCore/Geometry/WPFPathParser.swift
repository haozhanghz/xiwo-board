import CoreGraphics
import Foundation

/// Parses the path mini-language used by XAML/SVG (`M 0,0 L 10,10 C … Z`).
/// .enbx files store custom outlines and ink in this notation.
public enum WPFPathParser {
    public static func parse(_ string: String) -> CGPath? {
        var scanner = Tokenizer(string)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character = "M"
        var any = false

        while let tok = scanner.peek() {
            if case .command(let c) = tok {
                scanner.next()
                command = c
                if c == "F" { _ = scanner.number(); continue }
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = subpathStart
                    lastControl = nil; lastQuadControl = nil
                    continue
                }
            } else if !any {
                return nil
            }
            let rel = command.isLowercase
            func pt() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command.uppercased().first! {
            case "M":
                guard let p = pt() else { return any ? path : nil }
                path.move(to: p); current = p; subpathStart = p
                command = rel ? "l" : "L"
            case "L":
                guard let p = pt() else { return any ? path : nil }
                if path.isEmpty { path.move(to: current) }
                path.addLine(to: p); current = p
            case "H":
                guard let x = scanner.number() else { return any ? path : nil }
                let p = CGPoint(x: rel ? current.x + x : x, y: current.y)
                path.addLine(to: p); current = p
            case "V":
                guard let y = scanner.number() else { return any ? path : nil }
                let p = CGPoint(x: current.x, y: rel ? current.y + y : y)
                path.addLine(to: p); current = p
            case "C":
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return any ? path : nil }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2; current = p
                any = true; lastQuadControl = nil; continue
            case "S":
                guard let c2 = pt(), let p = pt() else { return any ? path : nil }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2; current = p
                any = true; lastQuadControl = nil; continue
            case "Q":
                guard let c = pt(), let p = pt() else { return any ? path : nil }
                path.addQuadCurve(to: p, control: c)
                lastQuadControl = c; current = p
                any = true; lastControl = nil; continue
            case "T":
                guard let p = pt() else { return any ? path : nil }
                let c = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addQuadCurve(to: p, control: c)
                lastQuadControl = c; current = p
                any = true; lastControl = nil; continue
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rot = scanner.number(),
                      let large = scanner.number(), let sweep = scanner.number(), let p = pt() else { return any ? path : nil }
                addArc(path, from: current, to: p, rx: rx, ry: ry, rotation: rot, largeArc: large != 0, sweep: sweep != 0)
                current = p
            default:
                scanner.next()
            }
            any = true
            lastControl = nil; lastQuadControl = nil
        }
        return any ? path : nil
    }

    /// SVG/XAML endpoint arc to cubic Béziers.
    static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: Double, ry ryIn: Double,
                       rotation: Double, largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / Double(segments)
        let t = 4.0 / 3.0 * tan(delta / 4)
        var th = theta1
        for _ in 0..<segments {
            let c1 = cos(th), s1 = sin(th), c2 = cos(th + delta), s2 = sin(th + delta)
            func map(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: cx + rx * x * cosPhi - ry * y * sinPhi, y: cy + rx * x * sinPhi + ry * y * cosPhi)
            }
            path.addCurve(to: map(c2, s2), control1: map(c1 - t * s1, s1 + t * c1), control2: map(c2 + t * s2, s2 - t * c2))
            th += delta
        }
    }

    enum Token: Equatable { case command(Character), number(Double) }

    struct Tokenizer {
        let chars: [Character]
        var i = 0
        var peeked: Token?
        init(_ s: String) { chars = Array(s) }

        mutating func peek() -> Token? {
            if peeked == nil { peeked = read() }
            return peeked
        }
        mutating func next() { if peeked == nil { _ = read() } else { peeked = nil } }
        mutating func number() -> Double? {
            if case .number(let v)? = peek() { peeked = nil; return v }
            return nil
        }
        private mutating func read() -> Token? {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i].isNewline || chars[i] == "\t" { i += 1 }
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c.isLetter && c != "e" && c != "E" { i += 1; return .command(c) }
            var s = ""
            if c == "-" || c == "+" { s.append(c); i += 1 }
            var seenDot = false, seenExp = false
            while i < chars.count {
                let d = chars[i]
                if d.isNumber { s.append(d); i += 1 }
                else if d == "." && !seenDot && !seenExp { seenDot = true; s.append(d); i += 1 }
                else if (d == "e" || d == "E") && !seenExp {
                    seenExp = true; s.append(d); i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
                } else { break }
            }
            if let v = Double(s) { return .number(v) }
            i += 1
            return read()
        }
    }
}
