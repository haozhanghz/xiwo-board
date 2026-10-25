import AppKit
import Metal
import OSLog
import QuartzCore
import XiwoCore

private let log = Logger(subsystem: "io.github.haozhanghz.xiwoboard", category: "ink")

/// Draws the stroke being written with Metal, in a transparent layer above the page.
///
/// Drawing live ink into the canvas itself meant every pen sample re-rasterised part of
/// the view on the CPU and committed the canvas's whole backing store again, about 2 ms
/// of main-thread work per sample on a full-screen page, and AppKit only redraws once per
/// display refresh. Here a sample only extends the stroke's geometry (`InkTessellator`);
/// the GPU redraws the stroke and the frame goes straight to the compositor, which shows
/// the newest one at its next refresh. The canvas is not touched until the pen lifts.
///
/// Then the canvas paints the stroke from the page image, and this layer keeps showing
/// it until that Core Animation transaction has gone to the window server. Only then is
/// the layer cleared, so both changes reach the screen in the same refresh: clearing any
/// earlier showed nothing for a frame or two, since committing the canvas can take that
/// long. The layer stays visible between strokes. Hiding it again meant showing it at the
/// next pen-down, and the first frames of every stroke then waited a refresh for that.
///
/// Frames are drawn on a thread of their own (`InkFrames`). A free drawable can take most
/// of a refresh to come back from the compositor; waiting for it on the main thread held
/// up the pen samples behind it, and the frame then showed the stroke as it was before
/// the wait.
@MainActor
final class LiveInkView: NSView {
    /// A frame reached the screen (presented time 0: it never did) and how many points of
    /// which stroke it showed. For the latency benchmark.
    var frameObserver: ((_ presented: CFTimeInterval, _ stroke: Int, _ points: Int) -> Void)? {
        didSet { frames.setObserver(frameObserver) }
    }
    /// Counts strokes, so frames can be matched to the samples they show.
    private(set) var strokeSerial = 0

    private let renderer: InkRenderer
    private let metalLayer: CAMetalLayer
    private let frames: InkFrames
    private var tessellator: InkTessellator?

    /// Nil when the Mac has no Metal device; the canvas then draws live ink itself.
    static func make() -> LiveInkView? {
        guard let renderer = InkRenderer.shared else { return nil }
        return LiveInkView(renderer: renderer)
    }

    private init(renderer: InkRenderer) {
        self.renderer = renderer
        let layer = CAMetalLayer()
        metalLayer = layer
        frames = InkFrames(layer: layer, queue: renderer.queue)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        // Same colour space the page is rendered in, so ink looks the same before and after it lands on the page.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Present as soon as the GPU is done instead of queueing a frame per refresh. Waiting for the
        // display link or the next transaction measured 50–60 ms from sample to screen, against 20 ms.
        layer.displaySyncEnabled = false
        // Shown at the first stroke, so a canvas nobody writes on has no layer to composite.
        isHidden = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { frames.stop() }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The pipeline is still compiling right after launch; until then the canvas draws live ink itself.
    var isReady: Bool { renderer.pipeline != nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancel() }
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let px = convertToBacking(bounds).size
        let size = CGSize(width: max(1, px.width.rounded()), height: max(1, px.height.rounded()))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            if tessellator != nil { frames.update { _ in } }
        }
    }

    // MARK: Stroke

    /// Starts a stroke. `slideRect` is where the page sits in this view and `scale` is view
    /// points per slide unit. Returns false when the canvas should draw the stroke itself.
    func begin(color: RGBA, width: Double, kind: PenKind, slideRect: CGRect, scale: CGFloat) -> Bool {
        guard let pipeline = renderer.pipeline, let window else { return false }
        let backing = window.backingScaleFactor
        let pixels = scale * backing
        // A tenth of a pixel: the flattened curve cannot be told from the one Core Graphics draws.
        tessellator = InkTessellator(width: width, kind: kind, tolerance: 0.1 / Double(max(pixels, 0.01)))
        strokeSerial += 1
        let c = kind == .highlighter ? color.withAlpha(min(color.a, 0.4)) : color
        // Live ink stays inside the page, as it does when the canvas draws it.
        let page = slideRect.intersection(bounds)
        let clip = page.isNull ? .zero : CGRect(x: page.minX * backing, y: page.minY * backing,
                                                width: page.width * backing, height: page.height * backing)
        let serial = strokeSerial
        // No frame for an empty stroke; the first point follows right away.
        frames.update(draw: false) { s in
            s.pieces.removeAll(keepingCapacity: true)
            s.fixed = 0
            s.color = SIMD4(Float(c.r * c.a), Float(c.g * c.a), Float(c.b * c.a), Float(c.a))
            s.origin = SIMD2(Float(slideRect.minX * backing), Float(slideRect.minY * backing))
            s.scale = Float(pixels)
            s.clip = clip
            s.pipeline = pipeline
            s.serial = serial
            s.points = 0
        }
        // Nothing has been drawn into the layer yet, or it was cleared after the last stroke.
        isHidden = false
        return true
    }

    /// The pen moved, or pressed down: extend the stroke and get it on screen.
    func append(_ p: StrokePoint) {
        guard tessellator != nil else { return }
        tessellator!.append(p)
        let t = tessellator!
        frames.update { s in
            s.pieces.removeSubrange(s.fixed...)
            for piece in t.fixed[s.fixed...] { s.pieces.append(InkPiece(piece)) }
            s.fixed = t.fixed.count
            for piece in t.tail { s.pieces.append(InkPiece(piece)) }
            s.points = t.points.count
        }
    }

    /// The stroke is done. Call it in the same run-loop pass in which the canvas paints the
    /// stroke from the page (or drops it); the layer clears once that has been committed.
    func end() {
        guard tessellator != nil else { return }
        tessellator = nil
        let serial = strokeSerial
        afterCommit { [weak self] in
            // A stroke started since then replaces this one with its first frame anyway.
            guard let self, self.tessellator == nil, self.strokeSerial == serial else { return }
            self.frames.update { s in
                s.pieces.removeAll(keepingCapacity: true)
                s.fixed = 0
                s.points = 0
            }
        }
    }

    /// Drops the stroke without handing it to the page.
    func cancel() { end() }
}

/// One `InkSegment` as the shader reads it.
struct InkPiece {
    var ax, ay, bx, by, width, endWidth: Float
    /// Bit 0: square start, bit 1: square end.
    var caps: UInt32

    init(_ s: InkSegment) {
        ax = Float(s.a.x); ay = Float(s.a.y); bx = Float(s.b.x); by = Float(s.b.y)
        width = Float(s.width); endWidth = Float(s.endWidth)
        caps = (s.squareStart ? 1 : 0) | (s.squareEnd ? 2 : 0)
    }
}

struct InkUniforms {
    /// Premultiplied.
    var color: SIMD4<Float>
    /// Drawable size in pixels.
    var viewport: SIMD2<Float>
    /// Where the slide's origin lands, in pixels.
    var origin: SIMD2<Float>
    /// Pixels per slide unit.
    var scale: Float
}

/// What the next frame shows.
private struct InkScene {
    var pieces: [InkPiece] = []
    /// How many of `pieces`, from the start, later points cannot change.
    var fixed = 0
    var color = SIMD4<Float>(0, 0, 0, 0)
    var origin = SIMD2<Float>(0, 0)
    var scale: Float = 1
    /// The page in drawable pixels. Ink outside it is cut off.
    var clip = CGRect.zero
    var pipeline: MTLRenderPipelineState?
    /// For `frameObserver`: which stroke, and how many of its points.
    var serial = 0
    var points = 0
}

/// Draws the newest `InkScene` into the layer, on a thread of its own.
///
/// The thread waits for a change, then for a free drawable, and only then reads the
/// scene, so samples that arrive while it waits still make the frame. A frame is drawn
/// whenever the stroke changed and a drawable is free; the compositor shows the newest
/// at each refresh.
private final class InkFrames: @unchecked Sendable {
    private let layer: CAMetalLayer
    private let queue: MTLCommandQueue
    private let condition = NSCondition()
    // Guarded by `condition`.
    private var scene = InkScene()
    private var changes = 0
    private var drawn = 0
    private var stopped = false
    private var observer: ((CFTimeInterval, Int, Int) -> Void)?
    // Only the render thread touches these.
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var next = 0
    /// Frames the GPU has not finished, so a buffer is never refilled while a frame still reads it.
    private let inFlight = DispatchSemaphore(value: 3)

    init(layer: CAMetalLayer, queue: MTLCommandQueue) {
        self.layer = layer
        self.queue = queue
        let thread = Thread { [self] in run() }
        thread.name = "XiwoBoard live ink"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Changes what the next frame shows; `draw: false` leaves it for the next change to
    /// put on screen. `change` runs under the lock the render thread reads the scene with,
    /// so it must be quick.
    func update(draw: Bool = true, _ change: (inout InkScene) -> Void) {
        condition.lock()
        change(&scene)
        if draw {
            changes += 1
            condition.signal()
        }
        condition.unlock()
    }

    /// Called on the main thread with each frame's presented time, stroke and point count.
    func setObserver(_ observer: ((CFTimeInterval, Int, Int) -> Void)?) {
        condition.lock()
        self.observer = observer
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while changes == drawn, !stopped { condition.wait() }
            let stop = stopped
            condition.unlock()
            if stop { return }
            inFlight.wait()
            let drew: Bool = autoreleasepool {
                guard let drawable = layer.nextDrawable() else { return false }
                draw(into: drawable)
                return true
            }
            if !drew {
                inFlight.signal()
                // No drawable for a second, or none at all at this size; try again shortly.
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    private func draw(into drawable: CAMetalDrawable) {
        let w = drawable.texture.width, h = drawable.texture.height
        condition.lock()
        drawn = changes
        let count = scene.pieces.count
        // Copied while locked, so the main thread is never left copying an array this thread still holds.
        let buffer = count > 0 ? fill(scene.pieces) : nil
        let u = InkUniforms(color: scene.color, viewport: SIMD2(Float(w), Float(h)), origin: scene.origin, scale: scene.scale)
        let clip = scene.clip, pipeline = scene.pipeline, serial = scene.serial, points = scene.points
        let observer = self.observer
        condition.unlock()

        guard let commands = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let inFlight = self.inFlight
        commands.addCompletedHandler { _ in inFlight.signal() }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            let x0 = Int(max(0, min(Double(w), clip.minX.rounded(.down)))), y0 = Int(max(0, min(Double(h), clip.minY.rounded(.down))))
            let x1 = Int(max(Double(x0), min(Double(w), clip.maxX.rounded(.up)))), y1 = Int(max(Double(y0), min(Double(h), clip.maxY.rounded(.up))))
            if let buffer, let pipeline, x1 > x0, y1 > y0 {
                encoder.setScissorRect(MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                encodeInk(buffer, count: count, uniforms: u, pipeline: pipeline, into: encoder)
            }
            encoder.endEncoding()
        }
        if let observer {
            drawable.addPresentedHandler { d in
                let t = d.presentedTime
                onMainRunLoop { observer(t, serial, points) }
            }
        }
        commands.present(drawable)
        commands.commit()
    }

    /// The next of the per-frame buffers, holding `pieces`.
    private func fill(_ pieces: [InkPiece]) -> MTLBuffer? {
        let bytes = pieces.count * MemoryLayout<InkPiece>.stride
        next = (next + 1) % buffers.count
        if (buffers[next]?.length ?? 0) < bytes {
            buffers[next] = layer.device?.makeBuffer(length: max(bytes * 2, 64 * 1024), options: .storageModeShared)
        }
        guard let buffer = buffers[next] else { return nil }
        pieces.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        return buffer
    }
}

/// The Metal device and pipeline live ink shares across canvases.
@MainActor
final class InkRenderer {
    static let shared: InkRenderer? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        return InkRenderer(device: device, queue: queue)
    }()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private(set) var pipeline: MTLRenderPipelineState?

    private init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
        compile()
    }

    /// Compiles the shaders in the background; the app builds with SwiftPM, which has no Metal step.
    private func compile() {
        device.makeLibrary(source: Self.shaderSource, options: nil) { [weak self] library, error in
            guard let library, let d = Self.pipelineDescriptor(library) else {
                log.error("Live ink shaders did not compile: \(String(describing: error), privacy: .public)")
                return
            }
            let device = library.device
            device.makeRenderPipelineState(descriptor: d) { state, error in
                guard let state else {
                    log.error("Live ink pipeline failed: \(String(describing: error), privacy: .public)")
                    return
                }
                onMainRunLoop { self?.pipeline = state }
            }
        }
    }

    /// The pipeline for `shaderSource` compiled into `library`.
    nonisolated static func pipelineDescriptor(_ library: MTLLibrary) -> MTLRenderPipelineDescriptor? {
        guard let vertex = library.makeFunction(name: "inkVertex"), let fragment = library.makeFunction(name: "inkFragment") else {
            return nil
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vertex
        d.fragmentFunction = fragment
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        // Pieces overlap at every joint. Taking the larger value instead of blending them
        // keeps a translucent highlighter one even tint, like a single Core Graphics stroke.
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .max
        c.alphaBlendOperation = .max
        c.sourceRGBBlendFactor = .one
        c.destinationRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationAlphaBlendFactor = .one
        return d
    }

    nonisolated static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Piece {
        packed_float2 a;
        packed_float2 b;
        float width;
        float endWidth;
        uint caps;
    };

    struct Uniforms {
        float4 color;
        float2 viewport;
        float2 origin;
        float scale;
    };

    struct Fragment {
        float4 position [[position]];
        float2 p;
        float2 a [[flat]];
        float2 b [[flat]];
        float r [[flat]];
        float rb [[flat]];
        uint caps [[flat]];
    };

    vertex Fragment inkVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device Piece *pieces [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        Piece s = pieces[iid];
        float2 a = u.origin + float2(s.a) * u.scale;
        float2 b = u.origin + float2(s.b) * u.scale;
        float r = s.width * 0.5 * u.scale;
        float rb = s.endWidth * 0.5 * u.scale;
        float2 d = b - a;
        float len = length(d);
        float2 dir = len > 1e-3 ? d / len : float2(1, 0);
        float2 nrm = float2(-dir.y, dir.x);
        // The quad around the piece, one pixel wider all round for antialiasing.
        float e = max(r, rb) + 1.0;
        float2 corner = float2((vid & 1) ? len + e : -e, (vid & 2) ? e : -e);
        float2 p = a + dir * corner.x + nrm * corner.y;
        Fragment f;
        f.position = float4(p.x / u.viewport.x * 2 - 1, 1 - p.y / u.viewport.y * 2, 0, 1);
        f.p = p;
        f.a = a;
        f.b = b;
        f.r = r;
        f.rb = rb;
        f.caps = s.caps;
        return f;
    }

    // How much of a one-pixel box centred t from a line falls within r of it.
    static float band(float t, float r) {
        return saturate(min(t + 0.5, r) - max(t - 0.5, -r));
    }

    // A piece of a pen with a nib: a disc of radius ra at a and one of rb at b, joined by
    // the lines tangent to both. Covered like a line of the local radius, by distance to the edge.
    static float cone(float2 p, float2 a, float2 b, float ra, float rb) {
        float2 d = b - a;
        float h = length(d);
        float r, edge;
        if (h <= abs(ra - rb)) {
            // One end's disc holds the other's.
            r = max(ra, rb);
            edge = length(p - (ra >= rb ? a : b)) - r;
        } else {
            float2 dir = d / h;
            float2 rel = p - a;
            float2 q = float2(abs(dot(rel, float2(-dir.y, dir.x))), dot(rel, dir));
            // The sides lean toward the narrower end; k is the sine of that angle.
            float k = (ra - rb) / h, c = sqrt(1 - k * k);
            float m = dot(q, float2(-k, c));
            if (m < 0) {
                r = ra;
                edge = length(q) - ra;
            } else if (m > c * h) {
                r = rb;
                edge = length(q - float2(0, h)) - rb;
            } else {
                r = mix(ra, rb, saturate(q.y / h));
                edge = dot(q, float2(c, k)) - ra;
            }
        }
        return band(edge + r, r);
    }

    fragment float4 inkFragment(Fragment f [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        if (f.r != f.rb) {
            return u.color * cone(f.p, f.a, f.b, f.r, f.rb);
        }
        float2 d = f.b - f.a;
        float len = length(d);
        float2 dir = len > 1e-3 ? d / len : float2(1, 0);
        float2 rel = f.p - f.a;
        float along = dot(rel, dir);
        float across = abs(dot(rel, float2(-dir.y, dir.x)));
        float c;
        if (along < 0) {
            c = (f.caps & 1) ? band(across, f.r) * saturate(f.r + 0.5 + along) : band(length(rel), f.r);
        } else if (along > len) {
            c = (f.caps & 2) ? band(across, f.r) * saturate(f.r + 0.5 - (along - len)) : band(length(f.p - f.b), f.r);
        } else {
            c = band(across, f.r);
        }
        return u.color * c;
    }
    """
}

/// Records `count` pieces from `buffer`, drawn with `pipeline`, into the pass `encoder` is recording.
func encodeInk(_ buffer: MTLBuffer, count: Int, uniforms: InkUniforms, pipeline: MTLRenderPipelineState,
               into encoder: MTLRenderCommandEncoder) {
    var u = uniforms
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    encoder.setVertexBytes(&u, length: MemoryLayout<InkUniforms>.stride, index: 1)
    encoder.setFragmentBytes(&u, length: MemoryLayout<InkUniforms>.stride, index: 1)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
}

/// Runs `body` on the main thread once the current Core Animation transaction has been
/// committed, as the run loop goes to sleep (or leaves a nested run loop).
@MainActor
private func afterCommit(_ body: @escaping @MainActor () -> Void) {
    // Core Animation commits from an observer of the same activities; this one is ordered last.
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                      false, CFIndex.max) { _, _ in MainActor.assumeIsolated(body) }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
}

/// Runs `body` on the main thread at its next run-loop pass, in whatever mode it runs.
/// Unlike the main dispatch queue, this also gets through while the main thread is inside
/// a block of that queue spinning a nested run loop, as the benchmark does.
private func onMainRunLoop(_ body: @escaping @MainActor () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { MainActor.assumeIsolated(body) }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}
