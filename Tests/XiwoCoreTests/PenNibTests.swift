import CoreGraphics
import XCTest
@testable import XiwoCore

final class PenNibTests: XCTestCase {
    /// A straight stroke written at 240 samples a second, `speed` view points per
    /// millisecond on screen. Returns the nib, the points and when the pen lifts.
    private func write(speed: Double, count: Int = 60, scale: Double = 1) -> (PenNib, [StrokePoint], TimeInterval) {
        var nib = PenNib(width: 4, scale: scale)
        var points: [StrokePoint] = []
        var t = 100.0
        for i in 0..<count {
            let p = CGPoint(x: 50 + Double(i) * speed * (1000 / 240) / scale, y: 80)
            points.append(StrokePoint(x: p.x, y: p.y, widthScale: nib.widthScale(at: p, time: t, pressure: nil)))
            t += 1 / 240
        }
        return (nib, points, t)
    }

    func testNibThinsWithSpeed() throws {
        let slow = write(speed: 0.02).1, fast = write(speed: 1.5).1
        XCTAssertEqual(try XCTUnwrap(slow.last?.widthScale), PenNib.slowScale, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(fast.last?.widthScale), PenNib.fastScale, accuracy: 0.01)
        // The width eases from one to the other instead of jumping.
        for (a, b) in zip(fast, fast.dropFirst()) { XCTAssertLessThan(abs(a.widthScale! - b.widthScale!), 0.1) }
        // The same speed on screen at another zoom writes the same line.
        let zoomed = write(speed: 1.5, scale: 2).1
        for (a, b) in zip(zoomed, fast) { XCTAssertEqual(a.widthScale!, b.widthScale!, accuracy: 0.0015) }
        // Pressing harder widens it.
        var light = PenNib(width: 4, scale: 1), hard = PenNib(width: 4, scale: 1)
        XCTAssertLessThan(light.widthScale(at: .zero, time: 0, pressure: 0.2), hard.widthScale(at: .zero, time: 0, pressure: 0.9))
    }

    /// A tablet's jitter moves the pen back and forth between samples; it must not read
    /// as speed, or a slow, careful line comes out thin and uneven.
    func testJitterDoesNotThinASlowLine() {
        var nib = PenNib(width: 4, scale: 1)
        var widths: [Double] = []
        for i in 0..<240 {
            // 0.05 points a millisecond, shaking by up to a point either way.
            let shake = sin(Double(i) * 12.9898) * 43758.5453
            let p = CGPoint(x: 50 + Double(i) * 0.05 * 1000 / 240, y: 80 + 2 * (shake - shake.rounded(.down) - 0.5))
            widths.append(nib.widthScale(at: p, time: 1 + Double(i) / 240, pressure: nil))
        }
        // Measured from one sample to the next, this shake thinned the line by up to 4 %
        // and made it waver by 3 %.
        let settled = widths.dropFirst(60)
        XCTAssertGreaterThan(settled.min()!, PenNib.slowScale - 0.01)
        XCTAssertLessThan(settled.max()! - settled.min()!, 0.005)
    }

    /// The pen lands at its plain width, not the fuller one it reaches if it stays, so a
    /// stroke does not start with a blot.
    func testPenLandsAtItsPlainWidth() {
        var mouse = PenNib(width: 4, scale: 1), tablet = PenNib(width: 4, scale: 1)
        XCTAssertEqual(mouse.widthScale(at: .zero, time: 0, pressure: nil), 1)
        XCTAssertEqual(tablet.widthScale(at: .zero, time: 0, pressure: 0.5), 1)
        XCTAssertEqual(mouse.widthScale(at: .zero, time: 0.004, pressure: nil), 1.02, accuracy: 0.01)
    }

    func testFlickEndsInAPoint() throws {
        let (nib, before, lift) = write(speed: 1.0)
        var points = before
        nib.taper(&points, liftedAt: lift)
        // Narrows to a tenth over the last seven pen widths (28 units, 4.2 apart here) and
        // leaves the rest alone.
        let end = points.suffix(8).map { $0.widthScale! }
        XCTAssertEqual(try XCTUnwrap(end.last), 0.1 * before.last!.widthScale!, accuracy: 0.002)
        XCTAssertEqual(end[0], before[before.count - 8].widthScale)
        for (a, b) in zip(end, end.dropFirst()) { XCTAssertGreaterThan(a, b) }
        XCTAssertEqual(Array(points.dropLast(8)), Array(before.dropLast(8)))
    }

    func testStoppingBeforeTheLiftKeepsTheEndRound() {
        // Resting 0.2 s before lifting.
        let (nib, before, lift) = write(speed: 1.0)
        var points = before
        nib.taper(&points, liftedAt: lift + 0.2)
        XCTAssertEqual(points, before)
        // Writing slowly up to the lift.
        let (slowNib, slowBefore, slowLift) = write(speed: 0.1)
        var slow = slowBefore
        slowNib.taper(&slow, liftedAt: slowLift)
        XCTAssertEqual(slow, slowBefore)
        // A short flick keeps its start.
        let (dotNib, dotBefore, dotLift) = write(speed: 1.0, count: 4)
        var dot = dotBefore
        dotNib.taper(&dot, liftedAt: dotLift)
        XCTAssertNotEqual(dot.last, dotBefore.last)
        XCTAssertEqual(dot[0], dotBefore[0])
    }

    func testNibWidthsSurviveSavingAndEditing() throws {
        // Saved as "w", and only when there is one, so older files read as before.
        let json = String(decoding: try JSONEncoder().encode([StrokePoint(x: 1, y: 2, widthScale: 0.5), StrokePoint(x: 3, y: 4)]), as: UTF8.self)
        XCTAssertTrue(json.contains("\"w\":0.5"))
        XCTAssertEqual(json.components(separatedBy: "\"w\"").count, 2)
        let old = try JSONDecoder().decode(StrokePoint.self, from: Data(#"{"x":1,"y":2,"pressure":0.5}"#.utf8))
        XCTAssertEqual(old, StrokePoint(x: 1, y: 2, pressure: 0.5))

        let pts = (0...100).map { StrokePoint(x: Double($0) * 2, y: 50, widthScale: 1 + Double($0) / 200) }
        var e = BoardElement.stroke(points: pts, color: .black, width: 10, kind: .pen)
        // The frame leaves room for the widest part, half of 1.5 × 10.
        XCTAssertEqual(e.frame.minY, 50 - 7.5 - 1, accuracy: 1e-9)
        XCTAssertEqual(e.absoluteStrokePoints, pts)
        let pieces = e.erasing(center: CGPoint(x: 101, y: 50), radius: 10)
        XCTAssertEqual(pieces.count, 2)
        for piece in pieces {
            for p in piece.absoluteStrokePoints { XCTAssertEqual(p.widthScale!, 1 + p.x / 400, accuracy: 1e-9) }
        }
        e.setFrame(e.frame.insetBy(dx: -10, dy: 0))
        XCTAssertEqual(e.absoluteStrokePoints.map(\.widthScale), pts.map(\.widthScale))
    }

    func testSimplifyKeepsWidthChanges() {
        // A straight line that swells in the middle.
        let pts = (0...20).map { StrokePoint(x: Double($0) * 5, y: 0, widthScale: $0 == 10 ? 1.4 : 1) }
        XCTAssertEqual(Geometry.simplify(pts, tolerance: 0.2).count, 2)
        let kept = Geometry.simplify(pts, tolerance: 0.2, width: 4)
        XCTAssertTrue(kept.contains(pts[10]))
        XCTAssertLessThan(kept.count, 6)
    }

    /// The finished stroke is filled from the same pieces the live ink draws, each a cone
    /// between two discs. Their outlines have to cover what those shapes cover, and the
    /// union of overlapping pieces has to stay filled.
    func testPieceOutlinesCoverTheirCones() {
        let pieces = [
            InkSegment(a: CGPoint(x: 10, y: 10), b: CGPoint(x: 50, y: 30), width: 12, endWidth: 2),
            InkSegment(a: CGPoint(x: 50, y: 30), b: CGPoint(x: 60, y: 60), width: 2, endWidth: 9),
            InkSegment(a: CGPoint(x: 80, y: 20), b: CGPoint(x: 82, y: 21), width: 16, endWidth: 3),
            InkSegment(a: CGPoint(x: 90, y: 60), b: CGPoint(x: 90, y: 60), width: 8),
        ]
        let path = CGMutablePath()
        pieces.forEach { $0.addOutline(to: path) }
        /// Inside the round-ended cone: within the local radius of the axis, or of an end.
        func inside(_ p: CGPoint, _ s: InkSegment) -> Double {
            let ra = s.width / 2, rb = s.endWidth / 2
            let dx = s.b.x - s.a.x, dy = s.b.y - s.a.y, len2 = dx * dx + dy * dy
            var best = min(hypot(p.x - s.a.x, p.y - s.a.y) - ra, hypot(p.x - s.b.x, p.y - s.b.y) - rb)
            guard len2 > 0, sqrt(len2) > abs(ra - rb) else { return best }
            // The sides touch the discs where the radius meets them at the cone's slant.
            let len = sqrt(len2), ux = dx / len, uy = dy / len
            let k = (ra - rb) / len, c = sqrt(1 - k * k)
            let along = (p.x - s.a.x) * ux + (p.y - s.a.y) * uy, across = abs(-(p.x - s.a.x) * uy + (p.y - s.a.y) * ux)
            let m = -k * across + c * along
            if m >= 0, m <= c * len { best = min(best, c * across + k * along - ra) }
            return best
        }
        var checked = 0
        for y in stride(from: 0.25, to: 80, by: 0.5) {
            for x in stride(from: 0.25, to: 110, by: 0.5) {
                let p = CGPoint(x: x, y: y)
                let d = pieces.map { inside(p, $0) }.min()!
                // Close to an edge, curves are approximated; elsewhere the fill must agree.
                guard abs(d) > 0.05 else { continue }
                XCTAssertEqual(path.contains(p, using: .winding), d < 0, "\(p)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 30_000)
    }
}
