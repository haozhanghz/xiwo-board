import CoreGraphics
import Foundation

/// Updating a rendered page in place, so a pen stroke or an eraser pass on a busy
/// slide only redraws the few hundred pixels it touched.
extension SlideRenderer {
    /// Stands in for "anywhere on the page" without the special-casing `CGRect.infinite` needs.
    static let wholePage = CGRect(x: -1e7, y: -1e7, width: 2e7, height: 2e7)

    /// Everything an element can paint, in slide coordinates. Text may run past the
    /// bottom of its box, so anything holding text reaches down to the page bottom,
    /// and rotated text could go anywhere.
    public static func paintBounds(of e: BoardElement) -> CGRect {
        func withText(_ box: CGRect) -> CGRect {
            guard e.rotation == 0 else { return wholePage }
            return CGRect(x: box.minX, y: box.minY, width: box.width, height: 1e7)
        }
        switch e.content {
        case .stroke, .image, .media:
            return e.boundingBox.insetBy(dx: -2, dy: -2)
        case .shape(let s):
            let lw = s.style.lineWidth
            let m = max(12, lw * 4) + lw + 4
            let box = e.boundingBox.insetBy(dx: -m, dy: -m)
            return (s.text ?? "").isEmpty ? box : withText(box)
        case .text, .table:
            return withText(e.boundingBox.insetBy(dx: -12, dy: -12))
        case .group(let children):
            guard e.rotation == 0 else { return wholePage }
            return children.reduce(e.boundingBox.insetBy(dx: -2, dy: -2)) { $0.union(paintBounds(of: $1)) }
        }
    }

    /// What can change on screen when the last of `points` has just been added to a
    /// stroke being written: the smoothed line only re-bends its last two segments and
    /// brush widths only look one point back, so the last three points bound it.
    public static func liveStrokeTail(_ points: [StrokePoint], width: Double, kind: PenKind) -> CGRect {
        let r = points.suffix(3).reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: 0, height: 0)) }
        // Square highlighter caps reach further out at their corners than half the width;
        // one more unit covers antialiasing.
        let pad = width * (kind == .highlighter ? 0.75 : 0.5) + 1
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
        guard let region = changedRegion(from: old, to: new) else { return nil }
        let page = CGRect(origin: .zero, size: courseware.slideSize)
        let r = region.intersection(page)
        guard !r.isNull, r.width > 0, r.height > 0 else { return image }
        guard r.width * r.height < page.width * page.height / 2 else { return nil }
        let w = image.width, h = image.height
        let scale = CGFloat(w) / page.width
        guard h == max(1, Int((page.height * scale).rounded())),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Whole device pixels, so the clip has no soft edge for old and new pixels to blend across.
        let minX = floor(r.minX * scale), maxX = ceil(r.maxX * scale)
        let minY = floor(CGFloat(h) - r.maxY * scale), maxY = ceil(CGFloat(h) - r.minY * scale)
        let px = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        ctx.clip(to: px)
        ctx.clear(px)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let area = CGRect(x: minX / scale, y: (CGFloat(h) - maxY) / scale, width: px.width / scale, height: px.height / scale)
        draw(new, courseware: courseware, in: ctx, options: options, only: area)
        return ctx.makeImage()
    }
}
