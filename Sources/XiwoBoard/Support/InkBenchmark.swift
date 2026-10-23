import AppKit
import QuartzCore
import XiwoCore

/// `XiwoBoard --ink-bench` writes synthetic handwriting into an offscreen canvas
/// and prints how long each pen move and each pen-up takes to draw, so changes to
/// the ink path can be compared on real hardware without touching the screen.
@MainActor
enum InkBenchmark {
    static let isRequested = CommandLine.arguments.contains("--ink-bench")

    static func runIfRequested() -> Bool {
        guard isRequested else { return false }
        NSApp.setActivationPolicy(.prohibited)
        NSApp.windows.forEach { $0.orderOut(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                NSApp.windows.forEach { $0.orderOut(nil) }
                run()
                exit(0)
            }
        }
        return true
    }

    struct Stats {
        var moves: [Double] = []
        var ups: [Double] = []
        var drawnPixels: Double = 0
        var draws = 0
        var drawTime: Double = 0
        var commitTime: Double = 0
    }

    static func run() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        print("screen \(Int(screen.frame.width))×\(Int(screen.frame.height)) @\(screen.backingScaleFactor)x")
        pageRender(pixelWidth: Int(screen.frame.width * screen.backingScaleFactor))
        for (mode, size) in [(BoardCanvasView.Mode.present, screen.frame.size), (.edit, CGSize(width: 1200, height: 760))] {
            for kind in PenKind.allCases {
                let s = bench(mode: mode, size: size, kind: kind, scale: screen.backingScaleFactor)
                let area = size.width * size.height
                print(String(format: "%@ %-11@ move avg %.2f p95 %.2f max %.2f ms | pen-up avg %.2f max %.2f ms | %.0f%% of view, %.2f ms per draw, %.2f ms CA commit per frame",
                             mode == .present ? "present" : "edit   ", kind.rawValue,
                             avg(s.moves), pct(s.moves, 0.95), s.moves.max() ?? 0, avg(s.ups), s.ups.max() ?? 0,
                             s.draws > 0 ? 100 * s.drawnPixels / Double(s.draws) / area : 0,
                             s.draws > 0 ? s.drawTime / Double(s.draws) : 0, s.commitTime / Double(max(1, s.moves.count + s.ups.count))))
            }
        }
    }

    static func bench(mode: BoardCanvasView.Mode, size: CGSize, kind: PenKind, scale: CGFloat) -> Stats {
        let doc = DocumentModel(courseware: busySlide())
        let tools = ToolState()
        tools.tool = .pen
        tools.penKind = kind
        tools.penWidth = kind == .highlighter ? 24 : 4
        let canvas = BoardCanvasView(document: doc, tools: tools, mode: mode)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        flush(canvas)

        var stats = Stats()
        flushTime = 0
        canvas.drawObserver = { rect, t in stats.drawnPixels += rect.width * rect.height; stats.draws += 1; stats.drawTime += t * 1000 }
        var clock = ProcessInfo.processInfo.systemUptime
        for stroke in handwriting() {
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                clock += 1.0 / 120
                return NSEvent.mouseEvent(with: type, location: canvas.convert(canvas.toView(p), to: nil), modifierFlags: [],
                                          timestamp: clock, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 1)!
            }
            canvas.mouseDown(with: event(.leftMouseDown, stroke[0]))
            flush(canvas)
            for p in stroke.dropFirst() {
                let t = CACurrentMediaTime()
                canvas.mouseDragged(with: event(.leftMouseDragged, p))
                flush(canvas)
                stats.moves.append((CACurrentMediaTime() - t) * 1000)
            }
            let t = CACurrentMediaTime()
            canvas.mouseUp(with: event(.leftMouseUp, stroke[stroke.count - 1]))
            RunLoop.main.run(mode: .default, before: Date())
            flush(canvas)
            stats.ups.append((CACurrentMediaTime() - t) * 1000)
        }
        stats.commitTime = flushTime
        return stats
    }

    /// Cost of putting one new stroke on the cached page: patching vs rendering it again.
    static func pageRender(pixelWidth: Int) {
        let cw = busySlide()
        let old = cw.slides[0]
        guard let base = SlideRenderer.image(of: old, courseware: cw, pixelWidth: pixelWidth) else { return }
        var full: [Double] = [], patch: [Double] = []
        for (i, stroke) in handwriting().prefix(40).enumerated() {
            var new = old
            new.elements.append(.stroke(points: stroke.map { StrokePoint(x: $0.x, y: $0.y) }, color: .red, width: 4, kind: .pen))
            var t = CACurrentMediaTime()
            _ = SlideRenderer.image(of: new, courseware: cw, pixelWidth: pixelWidth)
            if i > 0 { full.append((CACurrentMediaTime() - t) * 1000) }
            t = CACurrentMediaTime()
            _ = SlideRenderer.image(updating: base, from: old, to: new, courseware: cw)
            if i > 0 { patch.append((CACurrentMediaTime() - t) * 1000) }
        }
        print(String(format: "page %d px wide: full render avg %.2f ms, patch avg %.2f ms", pixelWidth, avg(full), avg(patch)))
    }

    private static var flushTime: Double = 0
    private static func flush(_ v: NSView) {
        v.displayIfNeeded()
        let t = CACurrentMediaTime()
        CATransaction.flush()
        flushTime += (CACurrentMediaTime() - t) * 1000
    }

    /// A page that has been taught on for a while: photo, text, a grid and lots of ink.
    static func busySlide() -> Courseware {
        var cw = Courseware(title: "bench")
        var slide = Slide(background: SlideBackground(pattern: .tianzige, patternColor: RGBA(0.2, 0.6, 0.3)))
        if let jpeg = photo(width: 2400, height: 1600) {
            let key = cw.addResource(data: jpeg, name: "photo", ext: "jpg")
            slide.elements.append(BoardElement(frame: CGRect(x: 700, y: 60, width: 540, height: 360), content: .image(ImageSpec(resource: key))))
        }
        slide.elements.append(BoardElement(frame: CGRect(x: 60, y: 40, width: 600, height: 120),
                                           content: .text(TextSpec(text: "春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。", fontSize: 36))))
        var rng = LCG(seed: 7)
        for _ in 0..<300 {
            let o = CGPoint(x: rng.next() * 1200, y: 180 + rng.next() * 500)
            let pts = (0..<40).map { (i: Int) -> StrokePoint in
                let t = Double(i)
                return StrokePoint(x: o.x + t * 1.5, y: o.y + sin(t / 5) * 12)
            }
            slide.elements.append(.stroke(points: pts, color: .blue, width: 4, kind: .pen))
        }
        cw.slides = [slide]
        return cw
    }

    /// Strokes for a few lines of characters, sampled like a 120 Hz trackpad, then one long scribble.
    static func handwriting() -> [[CGPoint]] {
        var rng = LCG(seed: 11)
        var strokes: [[CGPoint]] = []
        for row in 0..<2 {
            for col in 0..<8 {
                let cell = CGPoint(x: 80 + Double(col) * 140, y: 220 + Double(row) * 160)
                for _ in 0..<8 {
                    let a = CGPoint(x: cell.x + rng.next() * 90, y: cell.y + rng.next() * 90)
                    let angle = rng.next() * 2 * .pi, length = 30 + rng.next() * 60, bend = (rng.next() - 0.5) * 30
                    let n = Int(length / 3)
                    strokes.append((0...n).map { (i: Int) -> CGPoint in
                        let t = Double(i) / Double(n)
                        let along: Double = length * t, across: Double = bend * sin(t * .pi)
                        let x: Double = a.x + cos(angle) * along - sin(angle) * across
                        let y: Double = a.y + sin(angle) * along + cos(angle) * across
                        return CGPoint(x: x, y: y)
                    })
                }
            }
        }
        strokes.append((0..<1200).map { (i: Int) -> CGPoint in
            let t = Double(i) / 40
            let rx: Double = 60 + Double(i) / 6, ry: Double = 40 + Double(i) / 9
            return CGPoint(x: 640 + cos(t) * rx, y: 400 + sin(t) * ry)
        })
        return strokes
    }

    private static func photo(width: Int, height: Int) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        var rng = LCG(seed: 3)
        for _ in 0..<400 {
            ctx.setFillColor(red: rng.next(), green: rng.next(), blue: rng.next(), alpha: 0.6)
            let r = 40 + rng.next() * 300
            ctx.fillEllipse(in: CGRect(x: rng.next() * Double(width), y: rng.next() * Double(height), width: r, height: r))
        }
        guard let img = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    private static func pct(_ a: [Double], _ q: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * q))]
    }

    /// Small deterministic generator so every run writes the same strokes.
    struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }
}
