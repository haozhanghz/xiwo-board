import SwiftUI
import XiwoCore

/// Right-hand property panel: page settings when nothing is selected,
/// element properties otherwise.
struct InspectorView: View {
    @ObservedObject var doc: DocumentModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let sel = doc.selectedElements
                if sel.isEmpty {
                    PageInspector(doc: doc)
                } else {
                    ElementInspector(doc: doc, elements: sel)
                }
            }
            .padding(14)
            .frame(width: 270, alignment: .leading)
        }
        .background(.background)
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

struct PageInspector: View {
    @ObservedObject var doc: DocumentModel

    var body: some View {
        let bg = doc.slide.background
        InspectorSection(title: "页面背景") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(SlideBackground.presets.enumerated()), id: \.offset) { _, preset in
                    Button { doc.editSlide { $0.background = preset } } label: {
                        SlidePreview(slide: Slide(background: preset), courseware: doc.courseware, pixelWidth: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(bg == preset ? Color.accentColor : .gray.opacity(0.3),
                                                                              lineWidth: bg == preset ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker("背景颜色", selection: Binding(get: { Color(nsColor: bg.color.nsColor) },
                                                    set: { c in doc.editSlide { $0.background.color = RGBA(NSColor(c)) } }))
            Picker("书写格", selection: Binding(get: { bg.pattern }, set: { p in doc.editSlide { $0.background.pattern = p } })) {
                ForEach(BackgroundPattern.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            HStack {
                Button("背景图片…") {
                    guard let url = Exporter.chooseFiles([.image], multiple: false).first, let data = try? Data(contentsOf: url) else { return }
                    doc.edit { cw in
                        let key = cw.addResource(data: data, name: url.lastPathComponent, ext: url.pathExtension)
                        cw.slides[doc.currentIndex].background.image = key
                    }
                }
                if bg.image != nil { Button("移除") { doc.editSlide { $0.background.image = nil } } }
            }
            Button("应用到全部页面") {
                doc.edit { cw in for i in cw.slides.indices { cw.slides[i].background = bg } }
            }
        }
        InspectorSection(title: "翻页动画") {
            Picker("", selection: Binding(get: { doc.slide.transition }, set: { t in doc.editSlide { $0.transition = t } })) {
                ForEach(SlideTransition.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
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

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .frame(height: 120)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))
            .onAppear(perform: load)
            .onChange(of: doc.slide.id) { _, _ in load() }
            .onChange(of: text) { _, t in
                guard slideID == doc.slide.id, t != doc.slide.notes else { return }
                doc.editSlideLive { $0.notes = t }
            }
    }

    private func load() { slideID = doc.slide.id; text = doc.slide.notes }
}

struct ElementInspector: View {
    @ObservedObject var doc: DocumentModel
    let elements: [BoardElement]

    var first: BoardElement { elements[0] }

    var body: some View {
        InspectorSection(title: elements.count == 1 ? first.kindLabel : "\(elements.count) 个对象") {
            if elements.count == 1 { geometry }
            HStack {
                Text("透明度")
                Slider(value: Binding(get: { first.opacity }, set: { v in doc.updateSelected { $0.opacity = v } }), in: 0.1...1)
            }
        }
        styleSection
        InspectorSection(title: "排列") {
            HStack {
                iconButton("square.3.layers.3d.top.filled", "置于顶层") { doc.arrange(.front) }
                iconButton("square.2.layers.3d.top.filled", "上移一层") { doc.arrange(.forward) }
                iconButton("square.2.layers.3d.bottom.filled", "下移一层") { doc.arrange(.backward) }
                iconButton("square.3.layers.3d.bottom.filled", "置于底层") { doc.arrange(.back) }
            }
            HStack {
                iconButton("align.horizontal.left", "左对齐") { doc.align(.left) }
                iconButton("align.horizontal.center", "水平居中") { doc.align(.hCenter) }
                iconButton("align.horizontal.right", "右对齐") { doc.align(.right) }
                iconButton("align.vertical.top", "顶端对齐") { doc.align(.top) }
                iconButton("align.vertical.center", "垂直居中") { doc.align(.vCenter) }
                iconButton("align.vertical.bottom", "底端对齐") { doc.align(.bottom) }
            }
            HStack {
                Button("组合") { doc.groupSelection() }.disabled(elements.count < 2)
                Button("取消组合") { doc.ungroupSelection() }
                    .disabled(!elements.contains { if case .group = $0.content { return true } else { return false } })
            }
        }
        InspectorSection(title: "授课") {
            Toggle("锁定", isOn: flag(\.locked))
            Toggle("蒙层（点击或擦除后显示）", isOn: flag(\.masked))
            Toggle("克隆模式（拖动时复制）", isOn: flag(\.cloneOnDrag))
            if elements.count == 1 {
                TextField("超链接（网址或 页面:3）", text: Binding(get: { first.hyperlink ?? "" },
                                                           set: { v in doc.update(first.id) { $0.hyperlink = v.isEmpty ? nil : v } }))
            }
        }
        Button(role: .destructive) { doc.deleteSelection() } label: { Label("删除", systemImage: "trash") }
    }

    private func flag(_ kp: WritableKeyPath<BoardElement, Bool>) -> Binding<Bool> {
        Binding(get: { elements.allSatisfy { $0[keyPath: kp] } }, set: { v in doc.updateSelected { $0[keyPath: kp] = v } })
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 22, height: 20) }
            .buttonStyle(.borderless).help(help)
    }

    @ViewBuilder private var geometry: some View {
        let f = first.frame
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                NumberField(label: "X", value: f.minX) { v in doc.update(first.id) { $0.move(dx: v - $0.frame.minX, dy: 0) } }
                NumberField(label: "Y", value: f.minY) { v in doc.update(first.id) { $0.move(dx: 0, dy: v - $0.frame.minY) } }
            }
            GridRow {
                NumberField(label: "宽", value: f.width) { v in doc.update(first.id) { var r = $0.frame; r.size.width = v; $0.setFrame(r) } }
                NumberField(label: "高", value: f.height) { v in doc.update(first.id) { var r = $0.frame; r.size.height = v; $0.setFrame(r) } }
            }
            GridRow {
                NumberField(label: "旋转", value: first.rotation) { v in doc.update(first.id) { $0.rotation = v } }
                Color.clear.frame(height: 1)
            }
        }
    }

    @ViewBuilder private var styleSection: some View {
        switch first.content {
        case .text(let t):
            InspectorSection(title: "文字") { TextStyleEditor(spec: t) { new in doc.update(first.id) { $0.content = .text(new) } } }
        case .shape(let s):
            InspectorSection(title: "形状样式") {
                ShapeStyleEditor(style: s.style) { st in
                    doc.updateSelected { e in if case .shape(var sp) = e.content { sp.style = st; e.content = .shape(sp) } }
                }
                Picker("类型", selection: Binding(get: { s.type }, set: { t in
                    doc.update(first.id) { e in if case .shape(var sp) = e.content { sp.type = t; e.content = .shape(sp) } }
                })) {
                    ForEach(ShapeType.palette, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        case .stroke(let st):
            InspectorSection(title: "笔迹") {
                ColorSwatches(selection: Binding(get: { st.color }, set: { c in
                    doc.updateSelected { e in if case .stroke(var s) = e.content { s.color = c; e.content = .stroke(s) } }
                }))
                HStack {
                    Text("粗细")
                    Slider(value: Binding(get: { st.width }, set: { w in
                        doc.updateSelected { e in if case .stroke(var s) = e.content { s.width = w; e.content = .stroke(s) } }
                    }), in: 1...40)
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
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
            TextField("", text: $text, onCommit: { if let v = Double(text) { commit(v) } })
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, v in text = format(v) }
    }

    private func format(_ v: Double) -> String { String(Int(v.rounded())) }
}

struct TextStyleEditor: View {
    let spec: TextSpec
    let apply: (TextSpec) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("字体", selection: binding(\.fontName)) {
                ForEach(["PingFang SC", "Songti SC", "Kaiti SC", "Heiti SC", "Helvetica", "Times New Roman", "Menlo"], id: \.self) {
                    Text($0).tag($0)
                }
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
            Text("线条颜色").font(.caption)
            ColorSwatches(selection: Binding(get: { style.stroke }, set: { c in var s = style; s.stroke = c; apply(s) }))
            Toggle("填充", isOn: Binding(get: { style.fill != nil }, set: { on in var s = style; s.fill = on ? style.stroke.withAlpha(0.25) : nil; apply(s) }))
            if style.fill != nil {
                ColorSwatches(selection: Binding(get: { style.fill ?? .white }, set: { c in var s = style; s.fill = c; apply(s) }))
            }
            HStack {
                Text("线宽")
                Slider(value: Binding(get: { style.lineWidth }, set: { w in var s = style; s.lineWidth = w; apply(s) }), in: 1...20)
            }
            Toggle("虚线", isOn: Binding(get: { style.dashed }, set: { d in var s = style; s.dashed = d; apply(s) }))
        }
    }
}
