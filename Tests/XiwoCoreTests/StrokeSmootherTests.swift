import CoreGraphics
import XCTest
@testable import XiwoCore

final class StrokeSmootherTests: XCTestCase {
    /// Repeatable noise in -1...1.
    private func noise(_ i: Int, _ k: Int) -> Double {
        let v = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return (v - v.rounded(.down)) * 2 - 1
    }

    /// `path` sampled every `step` along its length, each point pushed off by up to `shake`.
    private func written(length: Double, step: Double = 1, shake: Double, _ path: (Double) -> CGPoint) -> [StrokePoint] {
        (0...Int((length / step + 1e-9).rounded(.down))).map { i in
            let p = path(Double(i) * step)
            return StrokePoint(x: p.x + shake * noise(i, 1), y: p.y + shake * noise(i, 2), pressure: 0.5 + 0.4 * noise(i, 3),
                               widthScale: 1 + 0.2 * noise(i, 4))
        }
    }

    private func steadied(_ pts: [StrokePoint], sigma: Double = 2.5) -> StrokeSmoother {
        var s = StrokeSmoother(sigma: sigma)
        for p in pts { s.append(p) }
        return s
    }

    private func rms(_ v: [Double]) -> Double { sqrt(v.reduce(0) { $0 + $1 * $1 } / Double(v.count)) }

    /// How much a line wiggles: its second differences across the stroke.
    private func wiggle(_ pts: [StrokePoint], _ across: (StrokePoint) -> Double) -> Double {
        rms((1..<(pts.count - 1)).map { across(pts[$0 - 1]) - 2 * across(pts[$0]) + across(pts[$0 + 1]) })
    }

    func testStraightensAShakyLine() {
        let line = written(length: 200, shake: 0.6) { CGPoint(x: 20 + $0, y: 50) }
        let s = steadied(line)
        XCTAssertEqual(s.points.count, line.count)
        XCTAssertLessThan(wiggle(s.points, \.y), wiggle(line, \.y) / 10)
        // Away from the ends every point has neighbours on both sides.
        let inner = line.indices.filter { line[$0].x >= 27.5 && line[$0].x <= 212.5 }
        let before = inner.map { abs(line[$0].y - 50) }, after = inner.map { abs(s.points[$0].y - 50) }
        XCTAssertLessThan(rms(after), rms(before) / 2)
        XCTAssertLessThan(after.max()!, 0.4)
        // The ends stay where the stroke starts and stops.
        XCTAssertEqual(s.points.first!.x, 20, accuracy: 1)
        XCTAssertEqual(s.points.first!.y, 50, accuracy: 1)
        XCTAssertEqual(s.points.last!.x, 220, accuracy: 1)
        XCTAssertEqual(s.points.last!.y, 50, accuracy: 1)
        // Pressure and width go with their points.
        XCTAssertEqual(s.points.map(\.pressure), line.map(\.pressure))
        XCTAssertEqual(s.points.map(\.widthScale), line.map(\.widthScale))
    }

    func testKeepsCornersSharp() {
        // Across, then down, as at the top right of 口.
        let pts = written(length: 120, shake: 0.4) { $0 <= 60 ? CGPoint(x: 20 + $0, y: 20) : CGPoint(x: 80, y: 20 + $0 - 60) }
        let s = steadied(pts)
        // Smoothed straight through, the line would cut the corner by about a point and a half.
        XCTAssertLessThan(s.points.map { hypot($0.x - 80, $0.y - 20) }.min()!, 0.6)
        let across = pts.indices.filter { pts[$0].x < 75 }, down = pts.indices.filter { pts[$0].y > 25 }
        XCTAssertLessThan(wiggle(across.map { s.points[$0] }, \.y), wiggle(across.map { pts[$0] }, \.y) / 5)
        XCTAssertLessThan(wiggle(down.map { s.points[$0] }, \.x), wiggle(down.map { pts[$0] }, \.x) / 5)
    }

    func testRoundStrokesKeepTheirSize() {
        let pts = written(length: .pi * 30, shake: 0.4) { CGPoint(x: 100 + 30 * cos($0 / 30), y: 100 + 30 * sin($0 / 30)) }
        let s = steadied(pts)
        let r = s.points.map { hypot($0.x - 100, $0.y - 100) - 30 }
        XCTAssertLessThan(r.map(abs).max()!, 0.3)
        XCTAssertLessThan(wiggle(s.points) { hypot($0.x - 100, $0.y - 100) }, wiggle(pts) { hypot($0.x - 100, $0.y - 100) } / 5)
    }

    /// What the canvas has drawn of the settled points never changes, the newest point is
    /// where the pen is, and the line when the pen lifts is the one on screen.
    func testSettledPointsStayPut() {
        // A wavy line with a sharp turn in it 70 along, written point by point.
        let pts = written(length: 150, step: 0.9, shake: 0.5) { s in
            s < 70 ? CGPoint(x: 20 + s, y: 40 + 6 * sin(s / 9)) : CGPoint(x: 90 + 6 * sin((s - 70) / 7), y: 40 + s - 70)
        }
        var s = StrokeSmoother(sigma: 2.5)
        var shown: [(stable: Int, points: [StrokePoint])] = []
        for (i, p) in pts.enumerated() {
            let from = s.append(p)
            XCTAssertEqual(from, shown.last?.stable ?? 0)
            if let previous = shown.last {
                XCTAssertEqual(Array(s.points[..<from]), Array(previous.points[..<from]), "point \(i)")
            }
            // Within the shake of the pen; just past the turn, until the pen is sigma past
            // it, the newest point still leans towards the line before it.
            let justTurned = (70...74).contains(Double(i) * 0.9)
            XCTAssertLessThan(hypot(s.points[i].x - p.x, s.points[i].y - p.y), justTurned ? 2 : 0.8, "point \(i)")
            shown.append((s.stable, s.points))
        }
        for (i, state) in shown.enumerated() {
            XCTAssertEqual(Array(state.points[..<state.stable]), Array(s.points[..<state.stable]), "after point \(i)")
        }
        // Points settle about seven sigma behind the pen.
        XCTAssertGreaterThan(shown[100].stable, 70)
    }

    func testOffAndShortStrokes() {
        let pts = written(length: 40, shake: 0.5) { CGPoint(x: 10 + $0, y: 10 + $0 / 2) }
        let off = steadied(pts, sigma: 0)
        XCTAssertEqual(off.points, pts)
        XCTAssertEqual(off.stable, pts.count)
        for n in 1...2 {
            let s = steadied(Array(pts.prefix(n)))
            for (a, b) in zip(s.points, pts) {
                XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
                XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
            }
        }
    }

    /// Live ink draws the settled points' pieces once and redoes the rest with every sample;
    /// together they have to be the pieces of the whole stroke.
    func testPiecesContinuingTheStrokeMatchTheWholeStroke() {
        for (kind, nib) in XiwoCoreTests.inkKinds {
            let pts = nib ? XiwoCoreTests.withNib(XiwoCoreTests.wavyStroke) : XiwoCoreTests.wavyStroke
            let all = InkTessellator.segments(of: Stroke(points: pts, color: .black, width: 8, kind: kind), tolerance: 0.05)
            for k in 0...pts.count {
                var t = InkTessellator(width: 8, kind: kind, tolerance: 0.05)
                for p in pts[..<k] { t.append(p) }
                XCTAssertEqual(t.fixed + t.pieces(continuingWith: Array(pts[k...])), all, "\(kind)\(nib ? " with nib" : ""), \(k) settled")
            }
        }
    }
}
