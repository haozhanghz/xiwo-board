import AppKit
import Combine
import QuartzCore
import XiwoCore

/// The drawing surface used by both the editor and the presenter.
///
/// Slide content is rendered into a cached bitmap; live ink, selection
/// chrome and presenter overlays (laser, spotlight, magnifier) are drawn on top.
@MainActor
final class BoardCanvasView: NSView, NSTextViewDelegate {
    enum Mode { case edit, present }

    let mode: Mode
    let document: DocumentModel
    let tools: ToolState
    /// Masks the presenter has tapped open on each slide.
    var revealedMasks: Set<String> = [] { didSet { invalidateCache() } }
    /// Called when an element with a hyperlink is clicked while presenting.
    var onHyperlink: ((String) -> Void)?
    /// Called for keys the canvas does not handle itself.
    var onKey: ((NSEvent) -> Bool)?
    var onPlayMedia: ((BoardElement) -> Void)?
    /// Benchmark hook: the rect each draw covered and how long it took, in seconds.
    var drawObserver: ((NSRect, Double) -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var cache: (image: CGImage, key: CacheKey, slide: Slide)?
    private struct CacheKey: Equatable {
        var revision: Int; var slide: Int; var size: CGSize; var page: CGSize; var hidden: Set<String>; var revealed: Set<String>
        /// Same page drawn the same way, so the old image can be patched rather than redrawn.
        func samePage(as other: CacheKey) -> Bool {
            slide == other.slide && size == other.size && page == other.page && hidden == other.hidden && revealed == other.revealed
        }
    }

    private enum Drag {
        case none
        case drawing
        case erasing(hasUndo: Bool)
        case moving(last: CGPoint, moved: Bool)
        case resizing(handle: Handle, original: BoardElement, start: CGPoint)
        case rotating(original: BoardElement)
        case marquee(start: CGPoint, current: CGPoint)
        case creatingShape(ShapeType, start: CGPoint, current: CGPoint)
        case laser
        case cloning(id: String, last: CGPoint)
    }

    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    private var drag: Drag = .none
    /// Points of the stroke being written. Kept outside `drag` so appending does not copy the array.
    private var liveStrokePoints: [StrokePoint] = []
    private var pointer: CGPoint?            // slide coordinates
    private var laserTrail: [(CGPoint, TimeInterval)] = []
    private var laserTimer: Timer?
    private var lastDragTime: TimeInterval = 0
    private var lastDragPoint: CGPoint = .zero
    private var tabletPressure = PenPressureFilter()
    /// Pointer speed for the brush, smoothed over a few samples (slide units per second).
    private var brushSpeed: Double = 0

    private var editor: NSTextView?
    private var editingID: String?
    private var editingCell: (row: Int, col: Int)?

    init(document: DocumentModel, tools: ToolState, mode: Mode) {
        self.document = document
        self.tools = tools
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        document.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }.store(in: &cancellables)
        tools.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.tools.tool != .text { self.endEditing() }
                self.window?.invalidateCursorRects(for: self)
                self.needsDisplay = true
            }
        }.store(in: &cancellables)
        TabletInput.shared.start()
        NotificationCenter.default.publisher(for: .tabletEraserChanged).sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.window?.invalidateCursorRects(for: self)
                self.needsDisplay = true
            }
        }.store(in: &cancellables)
    }

    /// The tool a press acts with: turning a tablet pen over to its eraser end
    /// erases while the pen tool is selected, without changing the toolbar choice.
    /// Without an event it answers for cursor and overlay drawing.
    private func activeTool(_ event: NSEvent? = nil) -> Tool {
        if tools.tool == .pen, TabletInput.shared.isEraser(event) { return .eraser }
        return tools.tool
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    // MARK: Geometry

    var slideSize: CGSize { document.courseware.slideSize }

    /// Where the slide sits inside the view (aspect fit, with a margin while editing).
    var slideRect: CGRect {
        let margin: CGFloat = mode == .edit ? 24 : 0
        let avail = bounds.insetBy(dx: margin, dy: margin)
        let s = min(avail.width / slideSize.width, avail.height / slideSize.height)
        let w = slideSize.width * s, h = slideSize.height * s
        return CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)
    }

    var scale: CGFloat { slideRect.width / slideSize.width }

    func toSlide(_ p: NSPoint) -> CGPoint {
        let r = slideRect
        return CGPoint(x: (p.x - r.minX) / scale, y: (p.y - r.minY) / scale)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        let r = slideRect
        return CGPoint(x: r.minX + p.x * scale, y: r.minY + p.y * scale)
    }

    func toView(_ rect: CGRect) -> CGRect {
        let o = toView(rect.origin)
        return CGRect(x: o.x, y: o.y, width: rect.width * scale, height: rect.height * scale)
    }

    // MARK: Drawing

    func invalidateCache() { cache = nil; needsDisplay = true }

    private func slideImage() -> CGImage? {
        let px = (slideRect.size.width * (window?.backingScaleFactor ?? 2)).rounded()
        let key = CacheKey(revision: document.revision, slide: document.currentIndex, size: CGSize(width: px, height: 0),
                           page: slideSize, hidden: editingID.map { [$0] } ?? [], revealed: revealedMasks)
        if let cache, cache.key == key { return cache.image }
        let opts = RenderOptions(drawMasks: true, maskOpacity: mode == .edit ? 0.55 : 1, revealedMasks: revealedMasks,
                                hidden: editingCell == nil ? key.hidden : [])
        let slide = document.slide
        // A new stroke or an eraser pass only repaints the pixels it touched.
        if let cache, cache.key.samePage(as: key),
           let img = SlideRenderer.image(updating: cache.image, from: cache.slide, to: slide, courseware: document.courseware, options: opts) {
            self.cache = (img, key, slide)
            return img
        }
        guard px > 1, let img = SlideRenderer.image(of: slide, courseware: document.courseware,
                                                    pixelWidth: Int(px), options: opts) else { return nil }
        cache = (img, key, slide)
        return img
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let started = drawObserver == nil ? 0 : CACurrentMediaTime()
        defer { drawObserver?(dirtyRect, CACurrentMediaTime() - started) }
        ctx.setFillColor((mode == .edit ? NSColor.underPageBackgroundColor : NSColor.black).cgColor)
        ctx.fill(bounds)
        let r = slideRect
        if mode == .edit {
            ctx.saveGState()
            // The shadow only shows outside the page; skip its blur when redrawing just a patch of ink.
            if !r.contains(dirtyRect) {
                ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 10, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(r)
            ctx.restoreGState()
        }
        if let img = slideImage() { SlideRenderer.drawImage(img, in: r, ctx: ctx) }

        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: scale, y: scale)
        drawLiveContent(ctx)
        ctx.restoreGState()

        drawSelectionChrome(ctx)
        drawOverlays(ctx)
    }

    private func drawLiveContent(_ ctx: CGContext) {
        switch drag {
        case .drawing:
            SlideRenderer.drawStroke(Stroke(points: liveStrokePoints, color: tools.penColor, width: tools.penWidth, kind: tools.penKind),
                                     origin: .zero, in: ctx)
        case .creatingShape(let type, let a, let b):
            let (rect, anti) = shapeRect(type, a, b)
            SlideRenderer.drawShape(ShapeSpec(type: type, style: tools.shapeStyle, antiDiagonal: anti), in: rect, ctx: ctx)
        default: break
        }
    }

    private func drawSelectionChrome(_ ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        if case .marquee(let a, let b) = drag {
            let rect = toView(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(accent); ctx.setLineWidth(1); ctx.stroke(rect)
        }
        guard tools.tool == .select, editingID == nil else { return }
        let selected = document.selectedElements
        guard !selected.isEmpty else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1.5)
        if selected.count == 1, let e = selected.first {
            withRotation(e, ctx) {
                let fr = toView(e.frame)
                ctx.setLineDash(phase: 0, lengths: e.locked ? [4, 3] : [])
                ctx.stroke(fr.insetBy(dx: -2, dy: -2))
                ctx.setLineDash(phase: 0, lengths: [])
                guard !e.locked, mode == .edit else { return }
                for h in Handle.allCases {
                    let c = handlePoint(h, fr)
                    let hr = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
                    ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: hr)
                    ctx.strokeEllipse(in: hr)
                }
                let top = CGPoint(x: fr.midX, y: fr.minY - 2)
                let rot = CGPoint(x: fr.midX, y: fr.minY - 28)
                ctx.move(to: top); ctx.addLine(to: rot); ctx.strokePath()
                ctx.setFillColor(accent)
                ctx.fillEllipse(in: CGRect(x: rot.x - 6, y: rot.y - 6, width: 12, height: 12))
            }
        } else if let u = BoardElement.union(selected) {
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.stroke(toView(u).insetBy(dx: -3, dy: -3))
        }
    }

    private func withRotation(_ e: BoardElement, _ ctx: CGContext, _ body: () -> Void) {
        ctx.saveGState()
        if e.rotation != 0 {
            let c = toView(e.center)
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: e.rotation * .pi / 180)
            ctx.translateBy(x: -c.x, y: -c.y)
        }
        body()
        ctx.restoreGState()
    }

    private func drawOverlays(_ ctx: CGContext) {
        guard let p = pointer else { return }
        let vp = toView(p)
        switch activeTool() {
        case .eraser:
            let r = tools.eraserSize / 2 * scale
            ctx.setStrokeColor(NSColor.gray.cgColor)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            ctx.fillEllipse(in: CGRect(x: vp.x - r, y: vp.y - r, width: 2 * r, height: 2 * r))
            ctx.strokeEllipse(in: CGRect(x: vp.x - r, y: vp.y - r, width: 2 * r, height: 2 * r))
        case .laser:
            let now = ProcessInfo.processInfo.systemUptime
            for (i, (pt, t)) in laserTrail.enumerated() where i > 0 {
                let age = now - t
                guard age < 0.6 else { continue }
                let a = toView(laserTrail[i - 1].0), b = toView(pt)
                ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.8 * (1 - age / 0.6)).cgColor)
                ctx.setLineWidth(6 * (1 - age / 0.6) + 1)
                ctx.setLineCap(.round)
                ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            }
            ctx.setShadow(offset: .zero, blur: 12, color: NSColor.systemRed.cgColor)
            ctx.setFillColor(NSColor.systemRed.cgColor)
            ctx.fillEllipse(in: CGRect(x: vp.x - 7, y: vp.y - 7, width: 14, height: 14))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        case .spotlight:
            let r = tools.spotlightRadius * scale
            ctx.saveGState()
            ctx.addRect(bounds)
            ctx.addEllipse(in: CGRect(x: vp.x - r, y: vp.y - r, width: 2 * r, height: 2 * r))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.82).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        case .magnifier:
            guard let img = cache?.image else { return }
            let r: CGFloat = 150
            let lens = CGRect(x: vp.x - r, y: vp.y - r, width: 2 * r, height: 2 * r)
            let z = tools.magnifierZoom
            let sr = slideRect
            let target = CGRect(x: vp.x - (vp.x - sr.minX) * z, y: vp.y - (vp.y - sr.minY) * z, width: sr.width * z, height: sr.height * z)
            ctx.saveGState()
            ctx.addEllipse(in: lens); ctx.clip()
            ctx.setFillColor(NSColor.black.cgColor); ctx.fill(lens)
            SlideRenderer.drawImage(img, in: target, ctx: ctx)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(4); ctx.strokeEllipse(in: lens)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.3).cgColor); ctx.setLineWidth(1); ctx.strokeEllipse(in: lens.insetBy(dx: -2, dy: -2))
        default: break
        }
    }

    private func handlePoint(_ h: Handle, _ r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        switch activeTool() {
        case .pen, .shape: cursor = .crosshair
        case .text: cursor = .iBeam
        case .laser, .spotlight, .magnifier, .eraser: cursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
        case .select: cursor = .arrow
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        pointer = toSlide(convert(event.locationInWindow, from: nil))
        if tools.tool == .laser { recordLaser() }
        let tool = activeTool()
        if tool.isOverlay || tool == .eraser { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = toSlide(convert(event.locationInWindow, from: nil))
        pointer = p
        lastDragPoint = p
        lastDragTime = event.timestamp
        if editingID != nil { endEditing() }

        switch activeTool(event) {
        case .pen:
            brushSpeed = 0
            liveStrokePoints = [StrokePoint(x: p.x, y: p.y, pressure: pressure(event, at: p))]
            drag = .drawing
            receiveEverySample(true)
            setNeedsDisplay(liveInkDirtyRect())
            return
        case .eraser:
            drag = .erasing(hasUndo: false)
            erase(at: p)
        case .laser:
            drag = .laser
            recordLaser()
        case .shape(let t):
            drag = .creatingShape(t, start: p, current: p)
        case .text:
            if let hit = topElement(at: p), case .text = hit.content {
                beginEditing(hit.id)
            } else {
                document.insertText("", at: p, spec: tools.textSpec)
                if let id = document.selection.first { beginEditing(id) }
            }
        case .spotlight, .magnifier:
            break
        case .select:
            selectDown(at: p, event: event)
        }
        needsDisplay = true
    }

    private func selectDown(at p: CGPoint, event: NSEvent) {
        // Handles of the single selected element come first.
        if mode == .edit, document.selection.count == 1, let e = document.selectedElements.first, !e.locked {
            let q = e.unrotate(p)
            let fr = e.frame
            let rot = CGPoint(x: fr.midX, y: fr.minY - 28 / scale)
            if hypot(q.x - rot.x, q.y - rot.y) < 10 / scale {
                document.beginGesture()
                drag = .rotating(original: e)
                return
            }
            for h in Handle.allCases {
                let c = handlePoint(h, fr)
                if hypot(q.x - c.x, q.y - c.y) < 8 / scale {
                    document.beginGesture()
                    drag = .resizing(handle: h, original: e, start: p)
                    return
                }
            }
        }
        guard let hit = topElement(at: p) else {
            if !event.modifierFlags.contains(.shift) { document.selection = [] }
            drag = .marquee(start: p, current: p)
            return
        }
        if mode == .present {
            if hit.masked && !revealedMasks.contains(hit.id) {
                revealedMasks.insert(hit.id)
                drag = .none
                return
            }
            if let link = hit.hyperlink, !link.isEmpty {
                onHyperlink?(link)
                drag = .none
                return
            }
            if case .media = hit.content { onPlayMedia?(hit); drag = .none; return }
            if hit.cloneOnDrag {
                let copy = hit.duplicated()
                document.insert(copy, select: true)
                drag = .cloning(id: copy.id, last: p)
                return
            }
        }
        if event.clickCount == 2, mode == .edit {
            switch hit.content {
            case .text: beginEditing(hit.id); return
            case .table: beginEditing(hit.id, at: p); return
            case .shape: beginEditing(hit.id); return
            case .media: onPlayMedia?(hit); return
            default: break
            }
        }
        if event.modifierFlags.contains(.shift) {
            if document.selection.contains(hit.id) { document.selection.remove(hit.id) } else { document.selection.insert(hit.id) }
        } else if !document.selection.contains(hit.id) {
            document.selection = [hit.id]
        }
        let movable = document.selectedElements.contains { !$0.locked }
        drag = movable ? .moving(last: p, moved: false) : .none
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toSlide(convert(event.locationInWindow, from: nil))
        pointer = p
        switch drag {
        case .drawing:
            let last = liveStrokePoints.last.map { CGPoint(x: $0.x, y: $0.y) } ?? p
            if hypot(p.x - last.x, p.y - last.y) >= 0.8 / scale {
                liveStrokePoints.append(StrokePoint(x: p.x, y: p.y, pressure: pressure(event, at: p)))
                setNeedsDisplay(liveInkDirtyRect())
            }
            lastDragPoint = p
            lastDragTime = event.timestamp
            return
        case .erasing:
            erase(at: p)
        case .laser:
            recordLaser()
        case .creatingShape(let t, let a, _):
            var b = p
            if event.modifierFlags.contains(.shift) {
                let d = max(abs(b.x - a.x), abs(b.y - a.y))
                b = CGPoint(x: a.x + (b.x >= a.x ? d : -d), y: a.y + (b.y >= a.y ? d : -d))
            }
            drag = .creatingShape(t, start: a, current: b)
        case .moving(let last, let moved):
            let dx = p.x - last.x, dy = p.y - last.y
            if !moved { document.beginGesture() }
            let ids = document.selection
            document.editSlideLive { s in
                for i in s.elements.indices where ids.contains(s.elements[i].id) && !s.elements[i].locked {
                    s.elements[i].move(dx: dx, dy: dy)
                }
            }
            drag = .moving(last: p, moved: true)
        case .cloning(let id, let last):
            document.editSlideLive { s in
                if let i = s.elements.firstIndex(where: { $0.id == id }) { s.elements[i].move(dx: p.x - last.x, dy: p.y - last.y) }
            }
            drag = .cloning(id: id, last: p)
        case .resizing(let h, let original, _):
            resize(original, handle: h, to: p, keepAspect: event.modifierFlags.contains(.shift) || isPicture(original))
        case .rotating(let original):
            let c = original.center
            var deg = atan2(p.y - c.y, p.x - c.x) * 180 / .pi + 90
            if event.modifierFlags.contains(.shift) { deg = (deg / 15).rounded() * 15 }
            else if abs(deg.truncatingRemainder(dividingBy: 90)) < 3 { deg = (deg / 90).rounded() * 90 }
            document.editSlideLive { s in
                if let i = s.elements.firstIndex(where: { $0.id == original.id }) { s.elements[i].rotation = deg }
            }
        case .marquee(let a, _):
            drag = .marquee(start: a, current: p)
            let r = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y))
            document.selection = Set(document.slide.elements.filter { r.intersects($0.boundingBox) && !$0.locked }.map(\.id))
        case .none:
            break
        }
        lastDragPoint = p
        lastDragTime = event.timestamp
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .drawing:
            receiveEverySample(false)
            // Tight enough that the stored line does not visibly shift from the one drawn live.
            let simplified = Geometry.simplify(liveStrokePoints, tolerance: min(0.35, 0.2 / scale))
            if !simplified.isEmpty {
                document.editSlide { $0.elements.append(.stroke(points: simplified, color: self.tools.penColor,
                                                                width: self.tools.penWidth, kind: self.tools.penKind)) }
            }
        case .creatingShape(let t, let a, let b):
            let (rect, anti) = shapeRect(t, a, b)
            let tiny = rect.width < 4 && rect.height < 4
            let final = tiny ? CGRect(x: a.x - 80, y: a.y - (t.isLine ? 0 : 60), width: 160, height: t.isLine ? 1 : 120) : rect
            document.insert(BoardElement(frame: final, content: .shape(ShapeSpec(type: t, style: tools.shapeStyle, antiDiagonal: anti))),
                            select: mode == .edit)
            if mode == .edit { tools.tool = .select }
        case .laser:
            break
        default:
            break
        }
        drag = .none
        liveStrokePoints.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        // A pen side button (XPPen maps one to right-click by default) erases
        // while writing, so the teacher need not go back to the toolbar.
        if tools.tool == .pen, event.isFromTablet {
            window?.makeFirstResponder(self)
            if editingID != nil { endEditing() }
            let p = toSlide(convert(event.locationInWindow, from: nil))
            pointer = p
            drag = .erasing(hasUndo: false)
            erase(at: p)
            needsDisplay = true
            return
        }
        guard mode == .edit else { return super.rightMouseDown(with: event) }
        let p = toSlide(convert(event.locationInWindow, from: nil))
        if let hit = topElement(at: p), !document.selection.contains(hit.id) { document.selection = [hit.id] }
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard case .erasing = drag else { return super.rightMouseDragged(with: event) }
        let p = toSlide(convert(event.locationInWindow, from: nil))
        pointer = p
        erase(at: p)
        needsDisplay = true
    }

    override func rightMouseUp(with event: NSEvent) {
        guard case .erasing = drag else { return super.rightMouseUp(with: event) }
        drag = .none
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        switch tools.tool {
        case .spotlight:
            tools.spotlightRadius = max(60, min(500, tools.spotlightRadius - event.scrollingDeltaY * 2))
        case .magnifier:
            tools.magnifierZoom = max(1.5, min(5, tools.magnifierZoom - event.scrollingDeltaY * 0.02))
        default:
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        guard mode == .edit else { return super.keyDown(with: event) }
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: document.deleteSelection()
        case 123: nudge(-step, 0)
        case 124: nudge(step, 0)
        case 125: nudge(0, step)
        case 126: nudge(0, -step)
        case 53: document.selection = []; tools.tool = .select
        default: super.keyDown(with: event)
        }
    }

    private func nudge(_ dx: Double, _ dy: Double) {
        guard !document.selection.isEmpty else { return }
        document.updateSelected { if !$0.locked { $0.move(dx: dx, dy: dy) } }
    }

    // MARK: Responder-chain edit commands

    @objc func undo(_ sender: Any?) { document.undo() }
    @objc func redo(_ sender: Any?) { document.redo() }
    @objc func copy(_ sender: Any?) { document.copySelection() }
    @objc func cut(_ sender: Any?) { document.cut() }
    @objc func paste(_ sender: Any?) { document.paste() }
    @objc func delete(_ sender: Any?) { document.deleteSelection() }
    override func selectAll(_ sender: Any?) { document.selectAll() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return document.canUndo
        case #selector(redo(_:)): return document.canRedo
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): return !document.selection.isEmpty
        default: return true
        }
    }

    // MARK: Gesture helpers

    private func pressure(_ event: NSEvent, at p: CGPoint) -> Double {
        if event.isFromTablet {
            if event.type == .leftMouseDown { tabletPressure.reset() }
            return tabletPressure.next(Double(event.pressure))
        }
        guard tools.penKind == .brush else { return 1 }
        // Mouse/trackpad: thinner when moving fast, like a brush. Samples arrive every
        // few milliseconds, so average the speed over ~40 ms or the width flickers.
        let dt = max(event.timestamp - lastDragTime, 0.001)
        let speed = hypot(p.x - lastDragPoint.x, p.y - lastDragPoint.y) / dt
        brushSpeed += (speed - brushSpeed) * min(1, dt / 0.04)
        return max(0.25, min(1, 1.1 - brushSpeed / 2500))
    }

    /// The part of the view the newest live-ink point changed.
    private func liveInkDirtyRect() -> NSRect {
        let tail = SlideRenderer.liveStrokeTail(liveStrokePoints, width: tools.penWidth, kind: tools.penKind)
        return toView(tail).insetBy(dx: -2, dy: -2)
    }

    /// AppKit merges queued mouse moves into one by default. While writing, take every
    /// sample the trackpad or tablet reports so fast strokes stay round instead of turning
    /// into polygons.
    private func receiveEverySample(_ on: Bool) {
        NSEvent.isMouseCoalescingEnabled = !on
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, case .drawing = drag {
            receiveEverySample(false)
            drag = .none
            liveStrokePoints.removeAll()
        }
    }

    private func shapeRect(_ t: ShapeType, _ a: CGPoint, _ b: CGPoint) -> (CGRect, Bool?) {
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: max(abs(a.x - b.x), t.isLine ? 0 : 1), height: abs(a.y - b.y))
        guard t.isLine else { return (rect, nil) }
        let anti = (b.x - a.x) * (b.y - a.y) < 0
        return (CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: max(rect.height, 1)), anti ? true : nil)
    }

    private func isPicture(_ e: BoardElement) -> Bool {
        switch e.content {
        case .image, .media: return true
        default: return false
        }
    }

    private func resize(_ original: BoardElement, handle: Handle, to p: CGPoint, keepAspect: Bool) {
        let q = original.unrotate(p)
        var f = original.frame
        var minX = f.minX, minY = f.minY, maxX = f.maxX, maxY = f.maxY
        switch handle {
        case .topLeft: minX = q.x; minY = q.y
        case .top: minY = q.y
        case .topRight: maxX = q.x; minY = q.y
        case .right: maxX = q.x
        case .bottomRight: maxX = q.x; maxY = q.y
        case .bottom: maxY = q.y
        case .bottomLeft: minX = q.x; maxY = q.y
        case .left: minX = q.x
        }
        f = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(abs(maxX - minX), 4), height: max(abs(maxY - minY), 4))
        let corner = [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle)
        if keepAspect && corner && original.frame.height > 0 {
            let ratio = original.frame.width / original.frame.height
            let w = max(f.width, f.height * ratio)
            let h = w / ratio
            let o = original.frame
            let x = (handle == .topLeft || handle == .bottomLeft) ? o.maxX - w : o.minX
            let y = (handle == .topLeft || handle == .topRight) ? o.maxY - h : o.minY
            f = CGRect(x: x, y: y, width: w, height: h)
        }
        document.editSlideLive { s in
            guard let i = s.elements.firstIndex(where: { $0.id == original.id }) else { return }
            var e = original
            e.setFrame(f)
            if case .text(let t) = e.content, !corner || !keepAspect {
                // Side handles re-wrap text; keep the box tall enough.
                e.frame.size.height = max(f.height, SlideRenderer.textHeight(t, width: f.width - 12) + 8)
            }
            s.elements[i] = e
        }
    }

    private func erase(at p: CGPoint) {
        let r = tools.eraserSize / 2
        let mode = tools.eraserMode
        let present = self.mode == .present
        var reveal: [String] = []
        var out: [BoardElement] = []
        let original = document.slide.elements
        for e in original {
            guard e.isStroke && !e.locked else {
                if present, e.masked, e.hitTest(p, tolerance: r) { reveal.append(e.id) }
                out.append(e); continue
            }
            if mode == .stroke {
                if !e.hitTest(p, tolerance: r) { out.append(e) }
            } else {
                out.append(contentsOf: e.erasing(center: p, radius: r))
            }
        }
        if out != original {
            if case .erasing(let hasUndo) = drag, !hasUndo {
                document.beginGesture()
                drag = .erasing(hasUndo: true)
            }
            document.editSlideLive { $0.elements = out }
        }
        if !reveal.isEmpty, !Set(reveal).isSubset(of: revealedMasks) { revealedMasks.formUnion(reveal) }
    }

    private func recordLaser() {
        guard let p = pointer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        laserTrail.append((p, now))
        laserTrail.removeAll { now - $0.1 > 0.6 }
        if laserTimer == nil {
            laserTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { t.invalidate(); return }
                    let now = ProcessInfo.processInfo.systemUptime
                    self.laserTrail.removeAll { now - $0.1 > 0.6 }
                    self.needsDisplay = true
                    if self.laserTrail.isEmpty || self.tools.tool != .laser { t.invalidate(); self.laserTimer = nil }
                }
            }
        }
    }

    func topElement(at p: CGPoint) -> BoardElement? {
        let tol = 6 / Double(scale)
        return document.slide.elements.reversed().first { $0.hitTest(p, tolerance: tol) }
    }

    // MARK: In-place text editing

    func beginEditing(_ id: String, at point: CGPoint? = nil) {
        document.finishEditing()
        guard let e = document.slide.element(id: id), !e.locked else { return }
        endEditing()
        var spec: TextSpec
        var rect = e.frame
        editingCell = nil
        switch e.content {
        case .text(let t):
            spec = t
        case .shape(let s):
            spec = TextSpec(text: s.text ?? "", fontSize: 28, color: s.style.stroke, alignment: .center)
            rect = e.frame.insetBy(dx: e.frame.width * 0.12, dy: max(4, e.frame.height * 0.3))
        case .table(let t):
            let p = point ?? CGPoint(x: e.frame.minX + 1, y: e.frame.minY + 1)
            let col = min(t.columns - 1, max(0, Int((p.x - e.frame.minX) / (e.frame.width / CGFloat(t.columns)))))
            let row = min(t.rows - 1, max(0, Int((p.y - e.frame.minY) / (e.frame.height / CGFloat(t.rows)))))
            editingCell = (row, col)
            spec = TextSpec(text: t.cells[row][col], fontSize: t.fontSize, alignment: .center)
            let cw = e.frame.width / CGFloat(t.columns), rh = e.frame.height / CGFloat(t.rows)
            rect = CGRect(x: e.frame.minX + CGFloat(col) * cw, y: e.frame.minY + CGFloat(row) * rh, width: cw, height: rh)
        default:
            return
        }
        editingID = id
        document.selection = [id]
        let tv = NSTextView(frame: toView(rect).insetBy(dx: 2, dy: 0))
        tv.delegate = self
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.white.withAlphaComponent(0.92)
        tv.font = NSFont(name: spec.fontName, size: spec.fontSize * scale) ?? .systemFont(ofSize: spec.fontSize * scale)
        tv.textColor = spec.color.luminance > 0.85 ? .black : NSColor(cgColor: spec.color.cgColor)
        tv.alignment = spec.alignment == .center ? .center : spec.alignment == .right ? .right : .left
        tv.string = spec.text
        tv.textContainerInset = NSSize(width: 2, height: 2)
        tv.isVerticallyResizable = true
        tv.wantsLayer = true
        tv.layer?.borderColor = NSColor.controlAccentColor.cgColor
        tv.layer?.borderWidth = 1.5
        addSubview(tv)
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        editor = tv
        document.commitPendingEditing = { [weak self] in self?.endEditing() }
        invalidateCache()
    }

    func endEditing() {
        guard let tv = editor, let id = editingID else { return }
        document.commitPendingEditing = nil
        let text = tv.string
        let cell = editingCell
        editor = nil
        editingID = nil
        editingCell = nil
        tv.removeFromSuperview()
        guard let e = document.slide.element(id: id) else { invalidateCache(); return }
        switch e.content {
        case .text(var t):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                document.editSlide { $0.elements.removeAll { $0.id == id } }
            } else if text != t.text {
                t.text = text
                let h = SlideRenderer.textHeight(t, width: e.frame.width - 12) + 8
                document.update(id) { $0.content = .text(t); $0.frame.size.height = max(h, 20) }
            }
        case .shape(var s):
            if (s.text ?? "") != text {
                s.text = text.isEmpty ? nil : text
                document.update(id) { $0.content = .shape(s) }
            }
        case .table(var t):
            if let cell, t.cells[cell.row][cell.col] != text {
                t.cells[cell.row][cell.col] = text
                document.update(id) { $0.content = .table(t) }
            }
        default: break
        }
        invalidateCache()
        window?.makeFirstResponder(self)
    }

    func textDidEndEditing(_ notification: Notification) { endEditing() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) { endEditing(); return true }
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = editor else { return }
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + 8
            if h > tv.frame.height { tv.frame.size.height = h }
        }
    }

    // MARK: Context menu

    private func contextMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ key: String = "", enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            item.isEnabled = enabled
            m.addItem(item)
        }
        let sel = document.selectedElements
        let has = !sel.isEmpty
        add("剪切", enabled: has) { [document] in document.cut() }
        add("复制", enabled: has) { [document] in document.copySelection() }
        add("粘贴") { [document] in document.paste() }
        add("删除", enabled: has) { [document] in document.deleteSelection() }
        m.addItem(.separator())
        add("组合", enabled: sel.count > 1) { [document] in document.groupSelection() }
        let isGroup = sel.contains { if case .group = $0.content { return true } else { return false } }
        add("取消组合", enabled: isGroup) { [document] in document.ungroupSelection() }
        add("置于顶层", enabled: has) { [document] in document.arrange(.front) }
        add("置于底层", enabled: has) { [document] in document.arrange(.back) }
        m.addItem(.separator())
        let locked = sel.allSatisfy(\.locked) && has
        add(locked ? "解除锁定" : "锁定", enabled: has) { [document] in document.updateSelected { $0.locked = !locked } }
        let masked = sel.allSatisfy(\.masked) && has
        add(masked ? "取消蒙层" : "添加蒙层", enabled: has) { [document] in document.updateSelected { $0.masked = !masked } }
        let clone = sel.allSatisfy(\.cloneOnDrag) && has
        add(clone ? "关闭授课克隆模式" : "打开授课克隆模式", enabled: has) { [document] in document.updateSelected { $0.cloneOnDrag = !clone } }
        add("超链接…", enabled: sel.count == 1) { [weak self] in self?.editHyperlink() }
        m.addItem(.separator())
        add("导出图片…", enabled: has) { [weak self] in self?.exportSelectionImage() }
        return m
    }

    private func editHyperlink() {
        guard let e = document.selectedElements.first else { return }
        let alert = NSAlert()
        alert.messageText = "超链接"
        alert.informativeText = "输入网址，或输入「页面:3」在授课时跳到第 3 页。留空则取消超链接。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = e.hyperlink ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let link = field.stringValue.trimmingCharacters(in: .whitespaces)
        document.update(e.id) { $0.hyperlink = link.isEmpty ? nil : link }
    }

    private func exportSelectionImage() {
        let els = document.selectedElements
        guard let u = BoardElement.union(els) else { return }
        var cw = document.courseware
        cw.slideSize = u.size
        let moved = els.map { e -> BoardElement in var c = e; c.move(dx: -u.minX, dy: -u.minY); return c }
        guard let img = SlideRenderer.image(of: Slide(background: SlideBackground(color: .clear), elements: moved), courseware: cw,
                                            pixelWidth: Int(u.width * 2)) else { return }
        Exporter.savePNG(img, suggestedName: "导出的图片")
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

extension RGBA {
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? ns
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }
}
