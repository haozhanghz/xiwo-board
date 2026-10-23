import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Decoded-image cache keyed by resource hash.
public final class ImageCache: @unchecked Sendable {
    private var images: [String: CGImage] = [:]
    private let lock = NSLock()

    public init() {}

    public func image(for key: String, in courseware: Courseware) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let img = images[key] { return img }
        guard let data = courseware.resources[key]?.data,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        images[key] = img
        return img
    }

    /// Lets the app supply images it decoded itself (e.g. video poster frames).
    public func set(_ image: CGImage, for key: String) {
        lock.lock(); images[key] = image; lock.unlock()
    }

    public static let shared = ImageCache()
}

public struct RenderOptions {
    /// Draw mask covers (蒙层) over masked elements.
    public var drawMasks: Bool
    /// Masks are translucent while editing so the author can see what is under them.
    public var maskOpacity: Double
    /// Masks the presenter has tapped away.
    public var revealedMasks: Set<String>
    /// Hide these element ids (e.g. a text box being edited in place).
    public var hidden: Set<String>
    public var cache: ImageCache

    public init(drawMasks: Bool = true, maskOpacity: Double = 1, revealedMasks: Set<String> = [], hidden: Set<String> = [],
                cache: ImageCache = .shared) {
        self.drawMasks = drawMasks; self.maskOpacity = maskOpacity; self.revealedMasks = revealedMasks; self.hidden = hidden; self.cache = cache
    }
}

/// Draws slides with Core Graphics. The context must already be set up in slide
/// coordinates with the origin at the top-left and y growing downwards.
public enum SlideRenderer {
    public static func draw(_ slide: Slide, courseware: Courseware, in ctx: CGContext, options: RenderOptions = RenderOptions()) {
        drawBackground(slide.background, size: courseware.slideSize, courseware: courseware, in: ctx, cache: options.cache)
        // Highlighter ink sits under everything else so text stays readable.
        for e in slide.elements where isHighlighter(e) && !options.hidden.contains(e.id) {
            draw(e, courseware: courseware, in: ctx, options: options)
        }
        for e in slide.elements where !isHighlighter(e) && !options.hidden.contains(e.id) {
            draw(e, courseware: courseware, in: ctx, options: options)
        }
    }

    static func isHighlighter(_ e: BoardElement) -> Bool {
        if case .stroke(let s) = e.content { return s.kind == .highlighter }
        return false
    }

    public static func drawBackground(_ bg: SlideBackground, size: CGSize, courseware: Courseware, in ctx: CGContext,
                                      cache: ImageCache = .shared) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.setFillColor(bg.color.cgColor)
        ctx.fill(rect)
        if let key = bg.image, let img = cache.image(for: key, in: courseware) {
            drawImage(img, in: rect, ctx: ctx)
        }
        drawPattern(bg.pattern, color: bg.patternColor, in: rect, ctx: ctx)
    }

    public static func drawPattern(_ pattern: BackgroundPattern, color: RGBA, in rect: CGRect, ctx: CGContext) {
        guard pattern != .none else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        switch pattern {
        case .none: break
        case .grid:
            let step: CGFloat = 40
            var x = rect.minX + step
            while x < rect.maxX { ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
            var y = rect.minY + step
            while y < rect.maxY { ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step }
            ctx.strokePath()
        case .ruled:
            var y = rect.minY + 60
            while y < rect.maxY { ctx.move(to: CGPoint(x: rect.minX + 40, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX - 40, y: y)); y += 60 }
            ctx.strokePath()
        case .dots:
            ctx.setFillColor(color.cgColor)
            var y = rect.minY + 30
            while y < rect.maxY {
                var x = rect.minX + 30
                while x < rect.maxX { ctx.fillEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)); x += 30 }
                y += 30
            }
        case .fourLines:
            // Four lines, three equal spaces; the third line (baseline) is drawn darker.
            let gap: CGFloat = 22, band: CGFloat = gap * 3, spacing: CGFloat = 50
            var top = rect.minY + 50
            while top + band < rect.maxY - 20 {
                for i in 0..<4 {
                    let y = top + CGFloat(i) * gap
                    ctx.setLineWidth(i == 2 ? 1.6 : 1)
                    ctx.move(to: CGPoint(x: rect.minX + 40, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX - 40, y: y))
                    ctx.strokePath()
                }
                top += band + spacing
            }
        case .tianzige:
            let cell: CGFloat = 90, gapY: CGFloat = 30
            let cols = Int((rect.width - 80) / cell)
            let left = rect.minX + (rect.width - CGFloat(cols) * cell) / 2
            var top = rect.minY + 40
            while top + cell <= rect.maxY - 20 {
                for c in 0..<cols {
                    let r = CGRect(x: left + CGFloat(c) * cell, y: top, width: cell, height: cell)
                    ctx.setLineDash(phase: 0, lengths: [])
                    ctx.setLineWidth(1.4)
                    ctx.stroke(r)
                    ctx.setLineWidth(0.8)
                    ctx.setLineDash(phase: 0, lengths: [4, 4])
                    ctx.move(to: CGPoint(x: r.midX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                    ctx.move(to: CGPoint(x: r.minX, y: r.midY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.midY))
                    ctx.strokePath()
                }
                ctx.setLineDash(phase: 0, lengths: [])
                top += cell + gapY
            }
        }
    }

    public static func draw(_ e: BoardElement, courseware: Courseware, in ctx: CGContext, options: RenderOptions = RenderOptions()) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        if e.rotation != 0 {
            ctx.translateBy(x: e.frame.midX, y: e.frame.midY)
            ctx.rotate(by: e.rotation * .pi / 180)
            ctx.translateBy(x: -e.frame.midX, y: -e.frame.midY)
        }
        ctx.setAlpha(e.opacity)
        let f = e.frame
        switch e.content {
        case .stroke(let s):
            drawStroke(s, origin: f.origin, in: ctx)
        case .shape(let s):
            drawShape(s, in: f, ctx: ctx)
        case .text(let t):
            if let bg = t.background {
                ctx.setFillColor(bg.cgColor); ctx.fill(f)
            }
            drawText(t, in: f.insetBy(dx: 6, dy: 4), ctx: ctx)
        case .image(let img):
            if let cg = options.cache.image(for: img.resource, in: courseware) {
                drawImage(cg, in: f, ctx: ctx)
            } else {
                drawPlaceholder("图片", in: f, ctx: ctx)
            }
        case .media(let m):
            drawMedia(m, in: f, courseware: courseware, ctx: ctx, cache: options.cache)
        case .table(let t):
            drawTable(t, in: f, ctx: ctx)
        case .group(let children):
            for c in children { draw(c, courseware: courseware, in: ctx, options: options) }
        }
        if e.masked && options.drawMasks && !options.revealedMasks.contains(e.id) {
            ctx.setAlpha(options.maskOpacity)
            drawMask(in: e.frame, ctx: ctx, label: options.maskOpacity >= 1)
        }
    }

    // MARK: Ink

    public static func drawStroke(_ s: Stroke, origin: CGPoint, in ctx: CGContext) {
        let pts = s.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
        guard !pts.isEmpty else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        switch s.kind {
        case .pen, .highlighter:
            let color = s.kind == .highlighter ? s.color.withAlpha(min(s.color.a, 0.4)) : s.color
            if pts.count == 1 {
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: pts[0].x - s.width / 2, y: pts[0].y - s.width / 2, width: s.width, height: s.width))
                return
            }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(s.width)
            ctx.setLineCap(s.kind == .highlighter ? .square : .round)
            ctx.setLineJoin(.round)
            ctx.addPath(smoothPath(pts))
            ctx.strokePath()
        case .brush:
            drawBrush(s, origin: origin, in: ctx)
        }
    }

    /// Quadratic smoothing through segment midpoints.
    public static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count < 3 {
            pts.dropFirst().forEach { p.addLine(to: $0) }
            return p
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }

    /// Brush pen: each segment is stroked at the width its pressure gives, with
    /// round caps so consecutive segments blend into one tapered line.
    static func drawBrush(_ s: Stroke, origin: CGPoint, in ctx: CGContext) {
        func width(_ p: StrokePoint) -> Double { s.width * (0.3 + 0.7 * max(0.05, min(1, p.pressure))) }
        let pts = s.points
        ctx.setStrokeColor(s.color.cgColor)
        ctx.setFillColor(s.color.cgColor)
        ctx.setLineCap(.round)
        guard pts.count > 1 else {
            if let p = pts.first {
                let w = width(p)
                ctx.fillEllipse(in: CGRect(x: p.x + origin.x - w / 2, y: p.y + origin.y - w / 2, width: w, height: w))
            }
            return
        }
        // Light smoothing of the pressure so the edge does not step.
        var widths = pts.map(width)
        if widths.count > 2 {
            for i in 1..<(widths.count - 1) { widths[i] = (widths[i - 1] + 2 * widths[i] + widths[i + 1]) / 4 }
        }
        for i in 1..<pts.count {
            ctx.setLineWidth((widths[i - 1] + widths[i]) / 2)
            ctx.move(to: CGPoint(x: pts[i - 1].x + origin.x, y: pts[i - 1].y + origin.y))
            ctx.addLine(to: CGPoint(x: pts[i].x + origin.x, y: pts[i].y + origin.y))
            ctx.strokePath()
        }
    }

    // MARK: Shapes

    public static func drawShape(_ s: ShapeSpec, in rect: CGRect, ctx: CGContext) {
        let path = ShapePath.path(for: s, in: rect)
        if let fill = s.style.fill, !s.type.isOpen {
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath(using: .evenOdd)
        }
        ctx.addPath(path)
        ctx.setStrokeColor(s.style.stroke.cgColor)
        ctx.setLineWidth(s.style.lineWidth)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        if s.style.dashed || s.type == .dottedLine {
            ctx.setLineDash(phase: 0, lengths: [s.style.lineWidth * 3, s.style.lineWidth * 2])
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        if let heads = ShapePath.arrowHeads(for: s, in: rect) {
            ctx.addPath(heads)
            ctx.setFillColor(s.style.stroke.cgColor)
            ctx.fillPath()
        }
        if let text = s.text, !text.isEmpty {
            drawText(TextSpec(text: text, fontSize: min(36, max(14, rect.height / 4)), color: s.style.stroke, alignment: .center),
                     in: rect.insetBy(dx: rect.width * 0.12, dy: 4), ctx: ctx, verticallyCentered: true)
        }
    }

    // MARK: Text

    public static func attributed(_ t: TextSpec) -> NSAttributedString {
        var font = CTFontCreateWithName(t.fontName as CFString, t.fontSize, nil)
        var traits: CTFontSymbolicTraits = []
        if t.bold { traits.insert(.traitBold) }
        if t.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, t.fontSize, nil, traits, traits) {
            font = styled
        }
        var alignment: CTTextAlignment = t.alignment == .center ? .center : t.alignment == .right ? .right : .left
        let para = withUnsafePointer(to: &alignment) { ptr in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ptr)
            return CTParagraphStyleCreate(&setting, 1)
        }
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): t.color.cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
        ]
        if t.underline {
            attrs[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: t.text, attributes: attrs)
    }

    /// Height needed to lay out `t` at `width`.
    public static func textHeight(_ t: TextSpec, width: Double) -> Double {
        let setter = CTFramesetterCreateWithAttributedString(attributed(t))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return max(size.height, t.fontSize * 1.3)
    }

    public static func drawText(_ t: TextSpec, in rect: CGRect, ctx: CGContext, verticallyCentered: Bool = false) {
        guard !t.text.isEmpty, rect.width > 1 else { return }
        let setter = CTFramesetterCreateWithAttributedString(attributed(t))
        var box = rect
        if verticallyCentered {
            let h = min(rect.height, textHeight(t, width: rect.width))
            box = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
        }
        // Core Text lays out bottom-up; flip locally around the box.
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.translateBy(x: 0, y: box.maxY + box.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let tall = CGRect(x: box.minX, y: box.minY - 10_000, width: box.width, height: box.height + 10_000)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: tall, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }

    // MARK: Pictures, media, tables

    public static func drawImage(_ img: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
    }

    static func drawPlaceholder(_ label: String, in rect: CGRect, ctx: CGContext) {
        ctx.setFillColor(RGBA(0.92, 0.93, 0.95).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(RGBA(0.7, 0.72, 0.76).cgColor)
        ctx.stroke(rect)
        drawText(TextSpec(text: label, fontSize: 18, color: RGBA(0.4, 0.42, 0.46), alignment: .center), in: rect, ctx: ctx,
                 verticallyCentered: true)
    }

    static func drawMedia(_ m: MediaSpec, in rect: CGRect, courseware: Courseware, ctx: CGContext, cache: ImageCache) {
        if m.kind == .video, let poster = cache.image(for: "poster:" + m.resource, in: courseware) {
            drawImage(poster, in: rect, ctx: ctx)
        } else {
            let rr = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.addPath(rr)
            ctx.setFillColor((m.kind == .video ? RGBA(0.15, 0.17, 0.22) : RGBA(0.93, 0.96, 1.0)).cgColor)
            ctx.fillPath()
        }
        // Play badge.
        let d = min(rect.width, rect.height) * 0.35
        let c = CGPoint(x: rect.midX, y: rect.midY - (m.kind == .audio ? 8 : 0))
        ctx.setFillColor(RGBA(0, 0, 0, 0.45).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
        ctx.setFillColor(RGBA.white.cgColor)
        ctx.move(to: CGPoint(x: c.x - d * 0.15, y: c.y - d * 0.22))
        ctx.addLine(to: CGPoint(x: c.x + d * 0.25, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x - d * 0.15, y: c.y + d * 0.22))
        ctx.fillPath()
        let labelColor = m.kind == .video ? RGBA.white : RGBA(0.2, 0.25, 0.35)
        drawText(TextSpec(text: m.name, fontSize: 14, color: labelColor, alignment: .center),
                 in: CGRect(x: rect.minX + 4, y: rect.maxY - 24, width: rect.width - 8, height: 22), ctx: ctx)
    }

    public static func drawTable(_ t: TableSpec, in rect: CGRect, ctx: CGContext) {
        let cw = rect.width / CGFloat(t.columns), rh = rect.height / CGFloat(t.rows)
        if let header = t.headerFill {
            ctx.setFillColor(header.cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rh))
        }
        ctx.setStrokeColor(t.borderColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(rect)
        for c in 1..<t.columns {
            ctx.move(to: CGPoint(x: rect.minX + CGFloat(c) * cw, y: rect.minY))
            ctx.addLine(to: CGPoint(x: rect.minX + CGFloat(c) * cw, y: rect.maxY))
        }
        for r in 1..<t.rows {
            ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + CGFloat(r) * rh))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + CGFloat(r) * rh))
        }
        ctx.strokePath()
        for r in 0..<t.rows {
            for c in 0..<t.columns where r < t.cells.count && c < t.cells[r].count && !t.cells[r][c].isEmpty {
                let cell = CGRect(x: rect.minX + CGFloat(c) * cw, y: rect.minY + CGFloat(r) * rh, width: cw, height: rh)
                drawText(TextSpec(text: t.cells[r][c], fontSize: t.fontSize, bold: r == 0, alignment: .center),
                         in: cell.insetBy(dx: 4, dy: 2), ctx: ctx, verticallyCentered: true)
            }
        }
    }

    static func drawMask(in rect: CGRect, ctx: CGContext, label: Bool) {
        let rr = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(rr)
        ctx.setFillColor(RGBA(0.36, 0.55, 0.85).cgColor)
        ctx.fillPath()
        guard label else { return }
        drawText(TextSpec(text: "点击揭开", fontSize: min(28, max(12, rect.height / 4)), color: .white, alignment: .center),
                 in: rect, ctx: ctx, verticallyCentered: true)
    }

    // MARK: Offscreen

    /// Renders a slide to a bitmap of `pixelSize` (thumbnails, export, recording previews).
    public static func image(of slide: Slide, courseware: Courseware, pixelWidth: Int, options: RenderOptions = RenderOptions()) -> CGImage? {
        let size = courseware.slideSize
        let scale = CGFloat(pixelWidth) / size.width
        let w = pixelWidth, h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(slide, courseware: courseware, in: ctx, options: options)
        return ctx.makeImage()
    }

    /// Writes every slide as one PDF page.
    public static func pdf(of courseware: Courseware, options: RenderOptions = RenderOptions(drawMasks: false)) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: courseware.slideSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: courseware.title] as CFDictionary)
        else { return Data() }
        for slide in courseware.slides {
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: 1, y: -1)
            draw(slide, courseware: courseware, in: ctx, options: options)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
