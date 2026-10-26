import AppKit
import Metal
import QuartzCore
import XiwoCore

/// `XiwoBoard --ink-latency` writes in a full-screen canvas the way a tablet does and
/// times every sample from the moment its event was made to the first frame that showed
/// it on screen.
///
/// A background thread posts pen events into the app's own event queue at 240 Hz (XPPen
/// tablets report 200–300 times a second), so they go through the normal event loop and
/// queue up whenever the main thread falls behind. Metal frames report when they were
/// presented. Ink drawn into the canvas has no such report, so a few pixels of Metal
/// (`TransactionProbe`) are presented with every canvas draw, in the same Core Animation
/// transaction, and report for it. That also shows whether the pen-up hand-over is clean:
/// the Metal layer should clear in the same refresh in which the page shows the stroke.
/// The window covers the screen for a few seconds per configuration and takes no clicks
/// or keys. `XIWO_LATENCY_ONLY="pen metal"` runs just the configurations whose name
/// contains that text.
@MainActor
final class InkLatency {
    struct Config {
        var name: String
        var metal: Bool
        var kind: PenKind
    }

    private struct Sample { var stroke: Int; var index: Int; var made: Double }
    /// A frame that reached the screen (`presented` 0: it never did), showing the first
    /// `points` points of `stroke`. `Int.max`: the page itself, with the whole stroke.
    private struct Frame { var presented: Double; var stroke: Int; var points: Int }

    static let rate = 240.0
    private static var running: InkLatency?

    static func start() {
        var configs: [Config] = []
        for kind in PenKind.allCases {
            configs.append(Config(name: "canvas (CG)", metal: false, kind: kind))
            configs.append(Config(name: "metal", metal: true, kind: kind))
        }
        if let only = ProcessInfo.processInfo.environment["XIWO_LATENCY_ONLY"] {
            configs = configs.filter { "\($0.kind.rawValue) \($0.name)".contains(only) }
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        print(String(format: "screen %d×%d @%.0fx, pen events at %.0f Hz, present mode on a busy page, hard pen %@ nib, steadiness %@",
                     Int(screen.frame.width), Int(screen.frame.height), screen.backingScaleFactor, rate,
                     ToolState.savedPenNib ? "with" : "without", ToolState.savedPenSteadiness.rawValue))
        run(configs[...])
    }

    private static func run(_ configs: ArraySlice<Config>) {
        guard let config = configs.first else {
            running = nil
            exit(0)
        }
        let current = InkLatency(config: config)
        running = current
        current.begin { run(configs.dropFirst()) }
    }

    private let config: Config
    private let window: NSWindow
    private let canvas: BoardCanvasView
    private let probe: TransactionProbe?
    private var samples: [Sample] = []
    private var frames: [Frame] = []
    private var ups: [Double] = []
    private var busy: [(start: Double, end: Double)] = []
    private var busyStart: Double?
    private var stroke = 0
    private var monitor: Any?
    private var observers: [CFRunLoopObserver] = []

    private init(config: Config) {
        self.config = config
        BoardCanvasView.metalInk = config.metal
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let doc = DocumentModel(courseware: InkBenchmark.busySlide())
        let tools = ToolState()
        tools.tool = .pen
        tools.penKind = config.kind
        tools.penWidth = config.kind == .highlighter ? 24 : 4
        canvas = BoardCanvasView(document: doc, tools: tools, mode: .present)
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.frame = NSRect(origin: .zero, size: screen.frame.size)
        probe = MTLCreateSystemDefaultDevice().flatMap { TransactionProbe(device: $0) }
        if let probe { canvas.addSubview(probe) }
    }

    private func begin(then next: @escaping () -> Void) {
        window.orderFrontRegardless()
        let ready = Date().addingTimeInterval(5)
        func waitForPipeline() {
            if config.metal, canvas.liveInk?.isReady != true, Date() < ready {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { waitForPipeline() } }
                return
            }
            // Let the first full draw settle before writing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { self.write(then: next) } }
        }
        waitForPipeline()
    }

    private func write(then next: @escaping () -> Void) {
        if config.metal && canvas.liveInk?.isReady != true { print("\(config.name): Metal pipeline never became ready") }
        canvas.liveInk?.frameObserver = { [weak self] t, serial, points in
            self?.frames.append(Frame(presented: t, stroke: serial, points: points))
        }
        canvas.drawObserver = { [weak self] _, _ in
            guard let self, let probe = self.probe else { return }
            // After the pen lifts, the canvas shows the whole stroke from the page image.
            let n = self.canvas.liveStrokePointCount
            let stroke = self.stroke, points = n == 0 ? Int.max : n
            probe.present { [weak self] t in self?.frames.append(Frame(presented: t, stroke: stroke, points: points)) }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self else { return e }
            switch e.type {
            case .leftMouseDown:
                self.stroke += 1
                self.samples.append(Sample(stroke: self.stroke, index: 0, made: e.timestamp))
            case .leftMouseDragged:
                let index = (self.samples.last?.stroke == self.stroke ? self.samples.last!.index : -1) + 1
                self.samples.append(Sample(stroke: self.stroke, index: index, made: e.timestamp))
            default:
                self.ups.append(CACurrentMediaTime())
            }
            return e
        }
        // Main-thread busy time: from waking up to going back to sleep, Core Animation's commit included.
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.busyStart = CACurrentMediaTime() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.busyStart else { return }
                self.busy.append((s, CACurrentMediaTime()))
                self.busyStart = nil
            }
        }
        for o in [wake, sleep] {
            if let o { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes); observers.append(o) }
        }

        // Window coordinates of every sample, worked out here so the posting thread only posts.
        var strokes = Array(InkBenchmark.handwriting().prefix(32))
        strokes.append(Array(InkBenchmark.handwriting().last!.prefix(480)))
        let canvas = self.canvas
        let paths = strokes.map { $0.map { canvas.convert(canvas.toView($0), to: nil) } }
        let windowNumber = window.windowNumber
        let interval = 1 / Self.rate
        Thread.detachNewThread {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            var deadline = mach_absolute_time()
            func wait(_ seconds: Double) {
                deadline += UInt64(seconds * 1e9 * Double(info.denom) / Double(info.numer))
                mach_wait_until(deadline)
            }
            func post(_ type: NSEvent.EventType, _ p: CGPoint) {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: CACurrentMediaTime(),
                                                 windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
                NSApp.postEvent(e, atStart: false)
            }
            for path in paths {
                post(.leftMouseDown, path[0])
                for p in path.dropFirst() {
                    wait(interval)
                    post(.leftMouseDragged, p)
                }
                wait(interval)
                post(.leftMouseUp, path[path.count - 1])
                // Pen lifted between strokes, as in quick handwriting.
                wait(0.06)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    guard let run = InkLatency.running else { return }
                    run.finish()
                    next()
                }
            }
        }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for o in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
        canvas.drawObserver = nil
        canvas.liveInk?.frameObserver = nil
        window.orderOut(nil)
        report()
    }

    private func report() {
        // Shown frames by stroke, in the order they reached the screen.
        var shown: [Int: [Frame]] = [:]
        for f in frames where f.presented > 0 { shown[f.stroke, default: []].append(f) }
        for k in shown.keys { shown[k]!.sort { $0.presented < $1.presented } }
        var latencies: [Double] = [], firsts: [Double] = []
        var missing = 0
        for s in samples {
            if let f = shown[s.stroke]?.first(where: { $0.points > s.index }) {
                latencies.append((f.presented - s.made) * 1000)
                if s.index == 0 { firsts.append((f.presented - s.made) * 1000) }
            } else {
                missing += 1
            }
        }
        let first = samples.first?.made ?? 0, last = (samples.last?.made ?? 0) + 0.05
        let during = busy.filter { $0.end > first && $0.start < last }
        let busyTotal = during.reduce(0) { $0 + min($1.end, last) - max($1.start, first) }
        let longest = during.map { $0.end - $0.start }.max() ?? 0
        let penUp = ups.map { u in busy.reduce(0) { $0 + max(0, min($1.end, u + 0.04) - max($1.start, u)) } * 1000 }
        let drawn = frames.filter { $0.presented > 0 }.count
        print(String(format: "%@ %-12@ latency avg %5.1f p50 %5.1f p95 %5.1f max %5.1f ms, first point %5.1f ms | main thread %.2f ms per sample (%.0f%% busy), longest %.1f ms | pen-up %.1f ms | %d frames shown, %d of %d samples never shown",
                     config.kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0), config.name,
                     avg(latencies), pct(latencies, 0.5), pct(latencies, 0.95), latencies.max() ?? 0, avg(firsts),
                     busyTotal * 1000 / Double(max(1, samples.count)), 100 * busyTotal / max(0.001, last - first), longest * 1000,
                     avg(penUp), drawn, missing, samples.count))
        if config.metal {
            // The frame that clears the Metal layer after a stroke should reach the screen together
            // with the page showing that stroke. Earlier, the ink vanishes for a moment; later, it
            // is drawn twice for a moment.
            var early = 0, late = 0, unseen = 0
            for stroke in 1...max(1, stroke) {
                let end = samples.last(where: { $0.stroke == stroke })?.made ?? 0
                guard let page = shown[stroke]?.first(where: { $0.points == Int.max }),
                      let clear = shown[stroke]?.last(where: { $0.points == 0 && $0.presented > end }) else { unseen += 1; continue }
                if clear.presented < page.presented - 0.001 { early += 1 } else if clear.presented > page.presented + 0.001 { late += 1 }
            }
            print("       pen-up hand-over: ink cleared before the page showed it \(early)×, after it \(late)×, not seen \(unseen)×")
        }
        fflush(stdout)
    }

    private func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    private func pct(_ a: [Double], _ q: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * q))]
    }
}

/// A few pixels of Metal presented together with what the canvas just drew, in the same
/// transaction, so the presented time says when that drawing reached the screen.
@MainActor
private final class TransactionProbe: NSView {
    private let metal = CAMetalLayer()
    private let queue: MTLCommandQueue
    private var flip = false

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        super.init(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
        wantsLayer = true
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.presentsWithTransaction = true
        metal.drawableSize = CGSize(width: 8, height: 8)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metal }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func present(onScreen: @escaping (CFTimeInterval) -> Void) {
        guard let drawable = metal.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        flip.toggle()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: flip ? 0.02 : 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        drawable.addPresentedHandler { d in
            let t = d.presentedTime
            DispatchQueue.main.async { MainActor.assumeIsolated { onScreen(t) } }
        }
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
    }
}
