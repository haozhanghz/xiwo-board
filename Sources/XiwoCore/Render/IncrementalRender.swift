import CoreGraphics
import Foundation

/// Updating a rendered page in place, so a pen stroke or an eraser pass on a busy
/// slide only redraws the few hundred pixels it touched.
extension SlideRenderer {
    /// Stands in for "anywhere on the page" without the special-casing `CGRect.infinite` needs.
    static let wholePage = CGRect(x: -1e7, y: -1e7, width: 2e7, height: 2e7)

    /// Everything an element can paint, in slide coordinates. Text may run past the
    /// bottom of its box, so anything holding text (mask labels and media names too)
    /// reaches down to the page bottom, and rotated text could go anywhere.
    public static func paintBounds(of e: BoardElement) -> CGRect {
        var box = e.boundingBox.insetBy(dx: -2, dy: -2)
        var hasText = e.masked
        switch e.content {
        case .stroke, .image:
            break
        case .media:
            hasText = true
        case .shape(let s):
            let lw = s.style.lineWidth
            let m = max(12, lw * 4) + lw + 4
            box = e.boundingBox.insetBy(dx: -m, dy: -m)
            hasText = hasText || !(s.text ?? "").isEmpty
        case .text, .table:
            box = e.boundingBox.insetBy(dx: -12, dy: -12)
            hasText = true
        case .group(let children):
            guard e.rotation == 0 else { return wholePage }
            box = children.reduce(box) { $0.union(paintBounds(of: $1)) }
        }
        guard hasText else { return box }
        guard e.rotation == 0 else { return wholePage }
        return CGRect(x: box.minX, y: box.minY, width: box.width, height: 1e7)
    }

    /// What can change on screen when the points of a stroke being written from `start` on
    /// have just been added or moved (by default only the last one): the smoothed line
    /// re-bends the two segments before a point and brush widths only look one point
    /// back, so those points and the two before them bound it.
    public static func liveStrokeTail(_ points: [StrokePoint], from start: Int? = nil, width: Double, kind: PenKind) -> CGRect {
        let tail = points[min(points.count, max(0, (start ?? points.count - 1) - 2))...]
        let r = tail.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: 0, height: 0)) }
        // Square highlighter caps reach further out at their corners than half the width,
        // and a nib can widen the pen at these points; one more unit covers antialiasing.
        let nib = kind == .pen ? tail.reduce(1) { max($0, $1.widthScale ?? 1) } : 1
        let pad = width * (kind == .highlighter ? 0.75 : 0.5 * nib) + 1
        return r.insetBy(dx: -pad, dy: -pad)
    }

    /// The part of the page that looks different between two versions of a slide:
    /// `.null` when nothing changed, nil when everything must be redrawn because the
    /// background or the stacking order changed.
    public static func changedRegion(from old: Slide, to new: Slide) -> CGRect? {
        guard old.background == new.background else { return nil }
        let before = Dictionary(old.elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(new.elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard before.count == old.elements.count, after.count == new.elements.count else { return nil }
        let kept = old.elements.map(\.id).filter { after[$0] != nil }
        guard kept == new.elements.map(\.id).filter({ before[$0] != nil }) else { return nil }
        var region = CGRect.null
        for e in old.elements where after[e.id] != e { region = region.union(paintBounds(of: e)) }
        for e in new.elements where before[e.id] != e { region = region.union(paintBounds(of: e)) }
        return region
    }

    /// Turns `image`, a render of `old` made by `image(of:)`, into a render of `new` by
    /// redrawing only the changed region. Returns nil when a full render is needed or
    /// would cost about the same.
    public static func image(updating image: CGImage, from old: Slide, to new: Slide, courseware: Courseware,
                             options: RenderOptions = RenderOptions()) -> CGImage? {
        guard let region = patchRegion(from: old, to: new, courseware: courseware) else { return nil }
        guard !region.isNull else { return image }
        let w = image.width, h = image.height
        guard fits(width: w, height: h, courseware), let ctx = bitmapContext(width: w, height: h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        redraw(region, of: new, in: ctx, courseware: courseware, options: options)
        return ctx.makeImage()
    }

    /// Brings `ctx`, a bitmap made by `bitmap(of:)` that holds a render of `old`, up to
    /// `new` in place, redrawing only what changed. Nothing is copied, so a stroke on a
    /// full-screen page costs only its own pixels. Returns false when a full render is
    /// needed or would cost about the same; `ctx` is then unchanged.
    public static func update(_ ctx: CGContext, from old: Slide, to new: Slide, courseware: Courseware,
                              options: RenderOptions = RenderOptions()) -> Bool {
        guard fits(width: ctx.width, height: ctx.height, courseware),
              let region = patchRegion(from: old, to: new, courseware: courseware) else { return false }
        if !region.isNull { redraw(region, of: new, in: ctx, courseware: courseware, options: options) }
        return true
    }

    /// The part of the page to redraw: `.null` for nothing, nil when a full render is due.
    private static func patchRegion(from old: Slide, to new: Slide, courseware: Courseware) -> CGRect? {
        guard let region = changedRegion(from: old, to: new) else { return nil }
        let page = CGRect(origin: .zero, size: courseware.slideSize)
        let r = region.intersection(page)
        guard !r.isNull, r.width > 0, r.height > 0 else { return .null }
        return r.width * r.height < page.width * page.height / 2 ? r : nil
    }

    /// A bitmap this size is what `image(of:)` gives for the page at this width.
    private static func fits(width: Int, height: Int, _ courseware: Courseware) -> Bool {
        let page = courseware.slideSize
        return page.width > 0 && height == max(1, Int((page.height * CGFloat(width) / page.width).rounded()))
    }

    /// Clears `r` (slide coordinates) in `ctx`, whose transform is the identity, and draws
    /// `slide` there again.
    private static func redraw(_ r: CGRect, of slide: Slide, in ctx: CGContext, courseware: Courseware, options: RenderOptions) {
        let h = ctx.height
        let scale = CGFloat(ctx.width) / courseware.slideSize.width
        // Whole device pixels, so the clip has no soft edge for old and new pixels to blend across.
        let minX = floor(r.minX * scale), maxX = ceil(r.maxX * scale)
        let minY = floor(CGFloat(h) - r.maxY * scale), maxY = ceil(CGFloat(h) - r.minY * scale)
        let px = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: px)
        ctx.clear(px)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let area = CGRect(x: minX / scale, y: (CGFloat(h) - maxY) / scale, width: px.width / scale, height: px.height / scale)
        draw(slide, courseware: courseware, in: ctx, options: options, only: area)
    }
}
