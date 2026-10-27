import SwiftUI
import XiwoCore

/// A small bar beside the chosen shapes, text or ink with their colour and the one setting each is
/// most often changed by, so they can be restyled without opening the property panel.
struct FormatBar: View {
    let state: FormatBarState
    let apply: (FormatChange) -> Void
    @AppStorage("InspectorShown") private var inspectorShown = false

    /// Room left around the bar for its shadow; the canvas places the bar by its visible edge.
    static let shadowRoom: CGFloat = 12

    static let fontSizes: [Double] = [12, 14, 16, 18, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 84, 96, 120, 144, 168, 200]

    /// The next size down (`step` -1) or up (+1) from `size`, nil past either end.
    static func fontSize(after size: Double, step: Int) -> Double? {
        step < 0 ? fontSizes.last { $0 < size - 0.5 } : fontSizes.first { $0 > size + 0.5 }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let size = state.fontSize {
                fontSizeButtons(size)
                separator
            }
            // The palette only; any other colour is in the property panel.
            ColorSwatches(selection: Binding(get: { state.color }, set: { apply(.color($0)) }), custom: false)
                .frame(width: 206)
            if let fill = state.fill {
                separator
                fillButtons(fill)
            }
            separator
            Button { inspectorShown.toggle() } label: {
                Image(systemName: "sidebar.right").font(.system(size: 14))
                    .foregroundStyle(inspectorShown ? Theme.text : Theme.secondaryText)
                    .frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle(active: inspectorShown, cornerRadius: 6))
            .help(inspectorShown ? "收起属性面板" : "更多设置（属性面板）")
            .accessibilityLabel(inspectorShown ? "收起属性面板" : "显示属性面板")
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(Self.shadowRoom)
        .fixedSize()
        .tint(Theme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("格式")
    }

    private var separator: some View {
        Rectangle().fill(Theme.divider).frame(width: 1, height: 20).padding(.horizontal, 3)
    }

    private func fontSizeButtons(_ size: Double) -> some View {
        HStack(spacing: 0) {
            stepButton("minus", "缩小字号", to: Self.fontSize(after: size, step: -1))
            Menu {
                ForEach(Self.fontSizes, id: \.self) { s in
                    Button("\(Int(s))") { apply(.fontSize(s)) }
                }
            } label: {
                Text("\(Int(size.rounded()))")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 32, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(QuietButtonStyle(cornerRadius: 6))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("字号")
            .accessibilityLabel("字号 \(Int(size.rounded()))")
            stepButton("plus", "放大字号", to: Self.fontSize(after: size, step: 1))
        }
    }

    private func stepButton(_ icon: String, _ label: String, to size: Double?) -> some View {
        Button { if let size { apply(.fontSize(size)) } } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(cornerRadius: 6))
        .disabled(size == nil)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Each choice drawn as the shape will look: an outline, a light wash, or solid.
    private func fillButtons(_ fill: ShapeFill) -> some View {
        HStack(spacing: 0) {
            ForEach(ShapeFill.allCases, id: \.self) { f in
                Button { apply(.fill(f)) } label: {
                    Circle().fill(f.color(outline: state.color).map { Color(nsColor: $0.nsColor) } ?? .clear)
                        .overlay(Circle().strokeBorder(Color(nsColor: state.color.nsColor), lineWidth: 1.5))
                        // Keeps a white outline visible on the light bar.
                        .overlay(Circle().strokeBorder(Theme.line).padding(-1))
                        .frame(width: 16, height: 16)
                        .frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle(active: f == fill, cornerRadius: 6))
                .help(f.label)
                .accessibilityLabel(f.label)
                .accessibilityAddTraits(f == fill ? .isSelected : [])
            }
        }
    }
}

/// What the format bar shows for a selection: the colour of its first coloured element, and
/// the fill or the font size when only shapes or only text are chosen.
struct FormatBarState: Equatable {
    var color: RGBA
    /// How closed shapes are filled; nil unless only shapes are chosen and one can be filled.
    var fill: ShapeFill?
    /// The font size; nil unless only text is chosen.
    var fontSize: Double?

    /// Nil when nothing chosen has a colour the bar sets, such as a picture or a table.
    init?(_ elements: [BoardElement]) {
        let coloured = elements.filter { $0.formatColor != nil }
        guard let color = coloured.first?.formatColor else { return nil }
        self.color = color
        let shapes = coloured.compactMap { e -> ShapeSpec? in if case .shape(let s) = e.content { s } else { nil } }
        if shapes.count == coloured.count, let closed = shapes.first(where: { !$0.type.isOpen }) {
            fill = ShapeFill(closed.style.fill)
        }
        let texts = coloured.compactMap { e -> TextSpec? in if case .text(let t) = e.content { t } else { nil } }
        if texts.count == coloured.count { fontSize = texts.first?.fontSize }
    }
}

/// How the format bar fills a closed shape: not at all, with a light wash of its outline colour, or solid.
enum ShapeFill: CaseIterable {
    case none, tint, solid

    init(_ fill: RGBA?) {
        guard let fill else { self = .none; return }
        self = fill.a > 0.99 ? .solid : .tint
    }

    /// The fill of a shape outlined in `stroke`; the wash is the property panel's.
    func color(outline stroke: RGBA) -> RGBA? {
        switch self {
        case .none: nil
        case .tint: stroke.withAlpha(0.25)
        case .solid: stroke.withAlpha(1)
        }
    }

    var label: String {
        switch self {
        case .none: "无填充"
        case .tint: "浅色填充"
        case .solid: "实心填充"
        }
    }
}

/// One change made in the format bar, applied to each chosen element it fits.
enum FormatChange {
    case color(RGBA)
    case fill(ShapeFill)
    case fontSize(Double)
}

extension BoardElement {
    /// The colour the format bar shows and sets: a shape's outline, a text's letters, a stroke's ink.
    var formatColor: RGBA? {
        switch content {
        case .shape(let s): s.style.stroke
        case .text(let t): t.color
        case .stroke(let s): s.color
        default: nil
        }
    }

    mutating func apply(_ change: FormatChange) {
        switch (content, change) {
        case (.shape(var s), .color(let c)):
            s.style.recolor(c)
            content = .shape(s)
        case (.shape(var s), .fill(let f)) where !s.type.isOpen:
            s.style.fill = f.color(outline: s.style.stroke)
            content = .shape(s)
        case (.text(var t), .color(let c)):
            t.color = c
            content = .text(t)
        case (.text(var t), .fontSize(let size)):
            let old = self
            t.fontSize = size
            content = .text(t)
            // Bigger letters wrap onto more lines; keep every line inside the box.
            refitText(was: old)
        case (.stroke(var s), .color(let c)):
            s.color = c
            content = .stroke(s)
        default:
            break
        }
    }
}

extension ShapeAppearance {
    /// Gives the outline a new colour. A fill washed from the old outline takes the new colour
    /// with it; a fill of a colour of its own stays as it is.
    mutating func recolor(_ c: RGBA) {
        if let f = fill, f.withAlpha(1) == stroke.withAlpha(1) { fill = c.withAlpha(f.a) }
        stroke = c
    }
}

extension ToolState {
    /// New shapes and text boxes take what the format bar last set on shapes and on text.
    func remember(_ change: FormatChange, from elements: [BoardElement]) {
        let shapes = elements.contains { if case .shape = $0.content { true } else { false } }
        let texts = elements.contains { if case .text = $0.content { true } else { false } }
        switch change {
        case .color(let c):
            if shapes { shapeStyle.recolor(c) }
            if texts { textSpec.color = c }
        case .fill(let f):
            if shapes { shapeStyle.fill = f.color(outline: shapeStyle.stroke) }
        case .fontSize(let size):
            if texts { textSpec.fontSize = size }
        }
    }
}
