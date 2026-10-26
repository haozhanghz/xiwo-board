import SwiftUI
import XiwoCore

/// Right-hand property panel: page settings when nothing is selected,
/// element properties otherwise.
struct InspectorView: View {
    @ObservedObject var doc: DocumentModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                let sel = doc.selectedElements
                if sel.isEmpty {
                    PageInspector(doc: doc)
                } else {
                    ElementInspector(doc: doc, elements: sel)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
            .frame(width: 280, alignment: .leading)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .controlSize(.small)
        .toggleStyle(SettingToggleStyle())
        .background(Theme.sidebar)
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    /// The first section of the panel has no line above it.
    var first = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !first { Hairline().padding(.bottom, 8) }
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            content()
        }
    }
}

/// A pop-up choice drawn like the panel's fields instead of the system pop-up button.
struct MenuField<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { value, title in Text(title).tag(value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack {
                Text(options.first { $0.0 == selection }?.1 ?? "").foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).frame(height: 28)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// Slider with its value shown at the end of the row.
struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int($0.rounded()))" }

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range)
            Text(format(value)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// A setting row: label on the left, a small switch on the right.
struct SettingToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

/// A labelled row in the property panel: fixed-width caption, then the control.
struct InspectorRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Theme.text).frame(width: 48, alignment: .leading)
            content()
        }
    }
}

struct PageInspector: View {
    @ObservedObject var doc: DocumentModel

    var body: some View {
        let bg = doc.slide.background
        InspectorSection(title: "页面背景", first: true) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(SlideBackground.presets, id: \.name) { name, preset in
                    Button { doc.editSlide { $0.background = preset } } label: {
                        SlidePreview(slide: Slide(background: preset), courseware: doc.courseware, pixelWidth: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.line))
                            .padding(2)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(bg == preset ? Theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(name)
                    .accessibilityLabel("背景：\(name)")
                    .accessibilityAddTraits(bg == preset ? .isSelected : [])
                }
            }
            InspectorRow(label: "颜色") {
                ColorPicker("背景颜色", selection: Binding(get: { Color(nsColor: bg.color.nsColor) },
                                                        set: { c in doc.editSlide { $0.background.color = RGBA(NSColor(c)) } }))
                    .labelsHidden()
                Spacer()
            }
            InspectorRow(label: "书写格") {
                MenuField(selection: Binding(get: { bg.pattern }, set: { p in doc.editSlide { $0.background.pattern = p } }),
                          options: BackgroundPattern.allCases.map { ($0, $0.displayName) })
            }
            HStack(spacing: 6) {
                Button("背景图片…") {
                    guard let url = Exporter.chooseFiles([.image], multiple: false).first, let data = try? Data(contentsOf: url) else { return }
                    doc.edit { cw in
                        let key = cw.addResource(data: data, name: url.lastPathComponent, ext: url.pathExtension)
                        cw.slides[doc.currentIndex].background.image = key
                    }
                }
                if bg.image != nil { Button("移除") { doc.editSlide { $0.background.image = nil } } }
                Button("应用到全部页面") {
                    doc.edit { cw in for i in cw.slides.indices { cw.slides[i].background = bg } }
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 28))
        }
        InspectorSection(title: "翻页动画") {
            MenuField(selection: Binding(get: { doc.slide.transition }, set: { t in doc.editSlide { $0.transition = t } }),
                      options: SlideTransition.allCases.map { ($0, $0.displayName) })
        }
        InspectorSection(title: "备注") {
            NotesEditor(doc: doc)
        }
    }
}

/// Edits notes without pushing an undo step per keystroke.
struct NotesEditor: View {
    @ObservedObject var doc: DocumentModel
    @State private var text = ""
    @State private var slideID = ""
    @State private var hasUndoPoint = false
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .focused($focused)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 120)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
            .onAppear(perform: load)
            .onChange(of: doc.slide.id) { _, _ in load() }
            .onChange(of: doc.slide.notes) { _, notes in
                if text != notes { text = notes; hasUndoPoint = false }
            }
            .onChange(of: focused) { _, _ in hasUndoPoint = false }
            .onChange(of: text) { _, t in
                guard slideID == doc.slide.id, t != doc.slide.notes else { return }
                if !hasUndoPoint { doc.beginGesture(); hasUndoPoint = true }
                doc.editSlideLive { $0.notes = t }
            }
    }

    private func load() { slideID = doc.slide.id; text = doc.slide.notes; hasUndoPoint = false }
}

struct ElementInspector: View {
    @ObservedObject var doc: DocumentModel
    let elements: [BoardElement]

    var first: BoardElement { elements[0] }

    var body: some View {
        InspectorSection(title: elements.count == 1 ? first.kindLabel : "\(elements.count) 个对象", first: true) {
            if elements.count == 1 {
                geometry
            } else {
                InspectorRow(label: "透明度") {
                ValueSlider(value: Binding(get: { first.opacity }, set: { v in doc.updateSelected { $0.opacity = v } }), range: 0.1...1,
                            format: { "\(Int(($0 * 100).rounded()))%" })
                }
            }
        }
        styleSection
        InspectorSection(title: "排列") {
            IconGroup {
                iconButton("square.3.layers.3d.top.filled", "置于顶层") { doc.arrange(.front) }
                iconButton("square.2.layers.3d.top.filled", "上移一层") { doc.arrange(.forward) }
                iconButton("square.2.layers.3d.bottom.filled", "下移一层") { doc.arrange(.backward) }
                iconButton("square.3.layers.3d.bottom.filled", "置于底层") { doc.arrange(.back) }
            }
            IconGroup {
                iconButton("align.horizontal.left", "左对齐") { doc.align(.left) }
                iconButton("align.horizontal.center", "水平居中") { doc.align(.hCenter) }
                iconButton("align.horizontal.right", "右对齐") { doc.align(.right) }
                iconButton("align.vertical.top", "顶端对齐") { doc.align(.top) }
                iconButton("align.vertical.center", "垂直居中") { doc.align(.vCenter) }
                iconButton("align.vertical.bottom", "底端对齐") { doc.align(.bottom) }
            }
            HStack(spacing: 6) {
                Button { doc.groupSelection() } label: { Text("组合").frame(maxWidth: .infinity) }
                    .disabled(elements.count < 2)
                Button { doc.ungroupSelection() } label: { Text("取消组合").frame(maxWidth: .infinity) }
                    .disabled(!elements.contains { if case .group = $0.content { return true } else { return false } })
            }
            .buttonStyle(SecondaryButtonStyle(height: 28))
            .font(.system(size: 13))
        }
        InspectorSection(title: "授课") {
            Toggle("锁定", isOn: flag(\.locked))
            Toggle("蒙层", isOn: flag(\.masked)).help("授课时点击或擦除后才显示下面的内容")
            Toggle("克隆", isOn: flag(\.cloneOnDrag)).help("授课时拖动它会复制出一个新的")
            if elements.count == 1 {
                TextField("超链接（网址或 页面:3）", text: Binding(get: { first.hyperlink ?? "" },
                                                           set: { v in doc.update(first.id) { $0.hyperlink = v.isEmpty ? nil : v } }))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line))
            }
        }
        Button(role: .destructive) { doc.deleteSelection() } label: {
            Label("删除", systemImage: "trash").foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
    }

    private func flag(_ kp: WritableKeyPath<BoardElement, Bool>) -> Binding<Bool> {
        Binding(get: { elements.allSatisfy { $0[keyPath: kp] } }, set: { v in doc.updateSelected { $0[keyPath: kp] = v } })
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(cornerRadius: 6)).help(help).accessibilityLabel(help)
    }

    @ViewBuilder private var geometry: some View {
        let f = first.frame
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                NumberField(label: "X", value: f.minX) { v in doc.update(first.id) { $0.move(dx: v - $0.frame.minX, dy: 0) } }
                NumberField(label: "Y", value: f.minY) { v in doc.update(first.id) { $0.move(dx: 0, dy: v - $0.frame.minY) } }
            }
            GridRow {
                NumberField(label: "宽", value: f.width) { v in
                    doc.update(first.id) { e in
                        let old = e
                        var r = e.frame; r.size.width = v; e.setFrame(r)
                        e.refitText(was: old)
                    }
                }
                NumberField(label: "高", value: f.height) { v in
                    doc.update(first.id) { e in var r = e.frame; r.size.height = v; e.setFrame(r); e.growToFitText() }
                }
            }
            GridRow {
                NumberField(label: "旋转", value: first.rotation) { v in doc.update(first.id) { $0.rotation = v } }
                NumberField(label: "透明度 %", value: first.opacity * 100) { v in
                    doc.updateSelected { $0.opacity = min(1, max(0.1, v / 100)) }
                }
            }
        }
    }

    @ViewBuilder private var styleSection: some View {
        switch first.content {
        case .text(let t):
            InspectorSection(title: "文字") {
                TextStyleEditor(spec: t) { new in
                    doc.update(first.id) { e in
                        guard case .text(let current) = e.content else { return }
                        let old = e
                        var styled = new
                        styled.text = current.text
                        e.content = .text(styled)
                        // A new size or font re-wraps the text; keep every line inside the box.
                        e.refitText(was: old)
                    }
                }
            }
        case .shape(let s):
            InspectorSection(title: "形状样式") {
                ShapeStyleEditor(style: s.style) { st in
                    doc.updateSelected { e in if case .shape(var sp) = e.content { sp.style = st; e.content = .shape(sp) } }
                }
                InspectorRow(label: "类型") {
                    MenuField(selection: Binding(get: { s.type }, set: { t in
                        doc.update(first.id) { e in if case .shape(var sp) = e.content { sp.type = t; e.content = .shape(sp) } }
                    }), options: ShapeType.palette.map { ($0, $0.displayName) })
                }
            }
        case .stroke(let st):
            InspectorSection(title: "笔迹") {
                ColorSwatches(selection: Binding(get: { st.color }, set: { c in
                    doc.updateSelected { e in if case .stroke(var s) = e.content { s.color = c; e.content = .stroke(s) } }
                }))
                InspectorRow(label: "粗细") {
                    ValueSlider(value: Binding(get: { st.width }, set: { w in
                        doc.updateSelected { e in if case .stroke(var s) = e.content { s.width = w; e.content = .stroke(s) } }
                    }), range: 1...40)
                }
            }
        case .table(let t):
            InspectorSection(title: "表格") {
                Stepper("行数 \(t.rows)", value: Binding(get: { t.rows }, set: { n in resizeTable(rows: n, cols: t.columns) }), in: 1...20)
                Stepper("列数 \(t.columns)", value: Binding(get: { t.columns }, set: { n in resizeTable(rows: t.rows, cols: n) }), in: 1...12)
                Text("双击单元格编辑内容").font(.caption).foregroundStyle(.secondary)
            }
        case .media(let m):
            InspectorSection(title: m.kind == .video ? "视频" : "音频") {
                Text(m.name).font(.callout).lineLimit(2)
                Toggle("翻到本页时自动播放", isOn: Binding(get: { m.autoPlay }, set: { v in
                    doc.update(first.id) { e in if case .media(var x) = e.content { x.autoPlay = v; e.content = .media(x) } }
                }))
                Toggle("循环播放", isOn: Binding(get: { m.loop }, set: { v in
                    doc.update(first.id) { e in if case .media(var x) = e.content { x.loop = v; e.content = .media(x) } }
                }))
            }
        default:
            EmptyView()
        }
    }

    private func resizeTable(rows: Int, cols: Int) {
        doc.update(first.id) { e in
            guard case .table(var t) = e.content else { return }
            var cells = Array(repeating: Array(repeating: "", count: cols), count: rows)
            for r in 0..<min(rows, t.rows) { for c in 0..<min(cols, t.columns) { cells[r][c] = t.cells[r][c] } }
            t.rows = rows; t.columns = cols; t.cells = cells
            e.content = .table(t)
        }
    }
}

struct NumberField: View {
    let label: String
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""

    var body: some View {
        // The caption sits inside the field, so every field in the grid lines up.
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.tertiaryText).fixedSize()
            TextField("", text: $text, onCommit: {
                if let v = Double(text), v.isFinite { commit(v) }
                text = format(value)
            })
                .textFieldStyle(.plain)
                .font(.system(size: 13).monospacedDigit())
                .accessibilityLabel(label)
        }
        .padding(.horizontal, 8).frame(width: 116, height: 28)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line))
        .onAppear { text = format(value) }
        .onChange(of: value) { _, v in text = format(v) }
    }

    private func format(_ v: Double) -> String { v.isFinite ? String(format: "%.0f", v) : "0" }
}

struct TextStyleEditor: View {
    let spec: TextSpec
    let apply: (TextSpec) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorRow(label: "字体") {
                MenuField(selection: binding(\.fontName),
                          options: ["PingFang SC", "Songti SC", "Kaiti SC", "Heiti SC", "Helvetica", "Times New Roman", "Menlo"].map { ($0, $0) })
            }
            Stepper("字号 \(Int(spec.fontSize))", value: binding(\.fontSize), in: 8...200, step: 2)
            HStack {
                Toggle(isOn: binding(\.bold)) { Image(systemName: "bold") }.toggleStyle(.button)
                Toggle(isOn: binding(\.italic)) { Image(systemName: "italic") }.toggleStyle(.button)
                Toggle(isOn: binding(\.underline)) { Image(systemName: "underline") }.toggleStyle(.button)
                Picker("", selection: binding(\.alignment)) {
                    Image(systemName: "text.alignleft").tag(XiwoCore.TextAlignment.left)
                    Image(systemName: "text.aligncenter").tag(XiwoCore.TextAlignment.center)
                    Image(systemName: "text.alignright").tag(XiwoCore.TextAlignment.right)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            ColorSwatches(selection: binding(\.color))
        }
    }

    private func binding<V>(_ kp: WritableKeyPath<TextSpec, V>) -> Binding<V> {
        Binding(get: { spec[keyPath: kp] }, set: { v in var s = spec; s[keyPath: kp] = v; apply(s) })
    }
}

struct ShapeStyleEditor: View {
    let style: ShapeAppearance
    let apply: (ShapeAppearance) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("线条颜色")
            ColorSwatches(selection: Binding(get: { style.stroke }, set: { c in var s = style; s.stroke = c; apply(s) }))
            Toggle("填充", isOn: Binding(get: { style.fill != nil }, set: { on in var s = style; s.fill = on ? style.stroke.withAlpha(0.25) : nil; apply(s) }))
            if style.fill != nil {
                ColorSwatches(selection: Binding(get: { style.fill ?? .white }, set: { c in var s = style; s.fill = c; apply(s) }))
            }
            InspectorRow(label: "线宽") {
                ValueSlider(value: Binding(get: { style.lineWidth }, set: { w in var s = style; s.lineWidth = w; apply(s) }), range: 1...20)
            }
            Toggle("虚线", isOn: Binding(get: { style.dashed }, set: { d in var s = style; s.dashed = d; apply(s) }))
        }
    }
}
