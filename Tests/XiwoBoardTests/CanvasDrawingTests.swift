import AppKit
import XCTest
import XiwoCore
@testable import XiwoBoard

final class CanvasDrawingTests: XCTestCase {
    /// After a pen-up the canvas repaints only the stroke's patch, drawing just that part
    /// of the page image; it has to look the same as drawing the whole page there.
    func testPatchRepaintMatchesWholePage() async throws {
        try await MainActor.run {
            var slide = Slide(background: SlideBackground(pattern: .tianzige))
            slide.elements = (0..<12).map { i in
                let o = Double(i) * 90
                return .stroke(points: (0..<20).map { StrokePoint(x: 40 + o + Double($0) * 4, y: 200 + sin(Double($0) / 3) * 60 + o / 3) },
                               color: .blue, width: 5, kind: .pen)
            }
            let metal = BoardCanvasView.metalInk
            BoardCanvasView.metalInk = false
            defer { BoardCanvasView.metalInk = metal }
            let canvas = BoardCanvasView(document: DocumentModel(courseware: Courseware(slides: [slide])), tools: ToolState(), mode: .present)
            // An odd size, so the page image is not exactly twice the view and gets resampled.
            canvas.frame = NSRect(x: 0, y: 0, width: 801, height: 451)
            @MainActor func render(_ rect: NSRect) throws -> NSBitmapImageRep {
                let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
                                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                rep.size = rect.size
                canvas.cacheDisplay(in: rect, to: rep)
                return rep
            }
            let whole = try render(canvas.bounds)
            for patch in [NSRect(x: 213, y: 101, width: 157, height: 93), NSRect(x: 0, y: 0, width: 60, height: 40),
                          NSRect(x: 700, y: 380, width: 101, height: 71)] {
                let part = try render(patch)
                let a = try XCTUnwrap(whole.bitmapData), b = try XCTUnwrap(part.bitmapData)
                var worst = 0
                for y in 0..<part.pixelsHigh {
                    for x in 0..<part.pixelsWide {
                        let i = (Int(patch.minY) * 2 + y) * whole.bytesPerRow + (Int(patch.minX) * 2 + x) * 4
                        let j = y * part.bytesPerRow + x * 4
                        for k in 0..<4 { worst = max(worst, abs(Int(a[i + k]) - Int(b[j + k]))) }
                    }
                }
                XCTAssertLessThanOrEqual(worst, 2, "\(patch)")
            }
        }
    }
}
