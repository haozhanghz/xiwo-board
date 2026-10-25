import CoreGraphics
import Metal
import XCTest
import XiwoCore
@testable import XiwoBoard

final class LiveInkShaderTests: XCTestCase {
    /// Run on the GPU, the live ink shader has to draw the line Core Graphics leaves on the
    /// page when the pen lifts, for every pen and for the nib: same place, same weight.
    func testShaderDrawsTheSameLineAsCoreGraphics() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        let library = try device.makeLibrary(source: InkRenderer.shaderSource, options: nil)
        let pipeline = try device.makeRenderPipelineState(descriptor: try XCTUnwrap(InkRenderer.pipelineDescriptor(library)))
        let scale = 2.0, w = 480, h = 320

        /// How much of each pixel the shader covers, rows from the top of the page.
        func shader(_ stroke: Stroke) throws -> [Double] {
            let pieces = InkTessellator.segments(of: stroke, tolerance: 0.1 / scale).map(InkPiece.init)
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = .renderTarget
            td.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: td))
            let buffer = try XCTUnwrap(pieces.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            })
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
            // Opaque black, premultiplied: the alpha a pixel ends up with is how much of it is covered.
            let u = InkUniforms(color: SIMD4(0, 0, 0, 1), viewport: SIMD2(Float(w), Float(h)), origin: SIMD2(0, 0), scale: Float(scale))
            encodeInk(buffer, count: pieces.count, uniforms: u, pipeline: pipeline, into: encoder)
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return (0..<(w * h)).map { Double(bytes[$0 * 4 + 3]) / 255 }
        }
        /// How much of each pixel Core Graphics covers, rows from the top of the page.
        func coreGraphics(_ stroke: Stroke) -> [Double] {
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            SlideRenderer.drawStroke(stroke, origin: .zero, in: ctx)
            // The highlighter is drawn at 40 % opacity.
            let alpha = stroke.kind == .highlighter ? 0.4 : 1
            return (0..<(w * h)).map { min(1, Double(data[$0 * 4 + 3]) / 255 / alpha) }
        }

        let wavy = (0..<24).map { (i: Int) -> StrokePoint in
            let t = Double(i)
            return StrokePoint(x: 30 + t * 8 + sin(t) * 6, y: 80 + cos(t * 0.7) * 45, pressure: 0.3 + 0.7 * abs(sin(t * 0.9)))
        }
        // Swelling and thinning, then narrowing to a point, as a nib writes.
        let nib = wavy.enumerated().map { i, p in
            var q = p
            q.widthScale = (0.6 + 0.6 * abs(sin(Double(i) * 0.5))) * max(0.1, min(1, Double(wavy.count - 1 - i) / 5))
            return q
        }
        for (kind, points) in PenKind.allCases.map({ ($0, wavy) }) + [(.pen, nib)] {
            let width = kind == .highlighter ? 20.0 : 8.0
            let name = "\(kind)\(points == nib ? " with nib" : "")"
            for n in [1, 2, 3, 5, points.count] {
                let stroke = Stroke(points: Array(points[0..<n]), color: .black, width: width, kind: kind)
                let a = coreGraphics(stroke), b = try shader(stroke)
                var worst = 0.0, total = 0.0, inked = 0
                for i in a.indices where a[i] > 0 || b[i] > 0 {
                    worst = max(worst, abs(a[i] - b[i]))
                    total += abs(a[i] - b[i])
                    inked += 1
                }
                XCTAssertGreaterThan(inked, 0, "\(name), \(n) points")
                // As in the CPU check of the same pieces: edges antialias a little differently,
                // and where two parts of the wide nib line nearly touch, the shader keeps the
                // larger of their coverages while Core Graphics adds them.
                XCTAssertLessThan(worst, points == nib ? 0.35 : 0.3, "\(name), \(n) points")
                XCTAssertLessThan(total / Double(max(1, inked)), 0.02, "\(name), \(n) points")
            }
        }
    }
}
