import SwiftUI
import XiwoCore

/// Big icon-over-label button used by the editor ribbon and presenter bar.
struct RibbonButton: View {
    let title: String
    let systemImage: String
    var active = false
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 17, weight: .medium)).frame(height: 20)
                Text(title).font(.system(size: 11))
            }
            .frame(minWidth: 46)
            .padding(.vertical, 5).padding(.horizontal, 4)
            .foregroundStyle(active ? Color.accentColor : (tint ?? Color.primary))
            .background(active ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A ribbon button that opens a popover.
struct RibbonPopoverButton<Content: View>: View {
    let title: String
    let systemImage: String
    var active = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @State private var shown = false

    var body: some View {
        RibbonButton(title: title, systemImage: systemImage, active: active) {
            if let onTap, !active { onTap() } else { shown.toggle() }
        }
        .popover(isPresented: $shown, arrowEdge: .bottom) { content().padding(12) }
    }
}

struct EditorToolbar: View {
    @ObservedObject var doc: DocumentModel
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var tools: ToolState
    @State private var title = ""

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Button("新建课件") { app.newDocument() }
                Button("打开课件…") { app.openWithPanel() }
                Divider()
                Button("保存") { Exporter.save(doc) }
                Button("另存为…") { Exporter.save(doc, forceChoose: true) }
                Divider()
                Button("导出为 .enbx…") { Exporter.exportEnbx(doc) }
                Button("导出为 PDF…") { Exporter.exportPDF(doc) }
                Button("导出为图片…") { Exporter.exportImages(doc) }
                Divider()
                Button("返回首页") { app.closeDocument() }
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .padding(.leading, 76) // clear the traffic lights

            TextField("课件名称", text: $title, onCommit: { doc.rename(title) })
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(width: 150)
                .onAppear { title = doc.title }
                .onChange(of: doc.title) { _, t in title = t }

            RibbonButton(title: "撤销", systemImage: "arrow.uturn.backward") { doc.undo() }.disabled(!doc.canUndo)
            RibbonButton(title: "恢复", systemImage: "arrow.uturn.forward") { doc.redo() }.disabled(!doc.canRedo)
            divider
            RibbonButton(title: "新建页面", systemImage: "plus.rectangle") { doc.addSlide() }
            RibbonButton(title: "选择", systemImage: "cursorarrow", active: tools.tool == .select) { tools.tool = .select }
            RibbonPopoverButton(title: "画笔", systemImage: "pencil.tip", active: tools.tool == .pen,
                                onTap: { tools.tool = .pen }) { PenSettings() }
            RibbonPopoverButton(title: "橡皮", systemImage: "eraser", active: tools.tool == .eraser,
                                onTap: { tools.tool = .eraser }) { EraserSettings(doc: doc) }
            divider
            RibbonButton(title: "文本", systemImage: "character.textbox", active: tools.tool == .text) { tools.tool = .text }
            RibbonPopoverButton(title: "形状", systemImage: "square.on.circle", active: isShapeTool) {
                ShapePicker { tools.tool = .shape($0) }
            }
            RibbonButton(title: "图片", systemImage: "photo") { Exporter.insertImages(into: doc) }
            RibbonButton(title: "音视频", systemImage: "film") { Exporter.insertMedia(into: doc) }
            RibbonPopoverButton(title: "表格", systemImage: "tablecells") { TablePicker { r, c in doc.insertTable(rows: r, columns: c) } }
            RibbonPopoverButton(title: "学科工具", systemImage: "function") { SubjectTools(doc: doc) }
            RibbonButton(title: "蒙层", systemImage: "rectangle.dashed.badge.record",
                         active: !doc.selectedElements.isEmpty && doc.selectedElements.allSatisfy(\.masked)) {
                let all = doc.selectedElements.allSatisfy(\.masked)
                doc.updateSelected { $0.masked = !all }
            }
            .disabled(doc.selection.isEmpty)
            Spacer(minLength: 8)
            Menu {
                Button("从当前页开始") { app.startPresentation() }
                Button("从第一页开始") { app.startPresentation(fromBeginning: true) }
            } label: {
                Label("授课", systemImage: "play.rectangle.fill")
                    .font(.headline)
            } primaryAction: {
                app.startPresentation()
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .fixedSize()
            .padding(.trailing, 12)
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var divider: some View { Divider().frame(height: 34).padding(.horizontal, 4) }

    private var isShapeTool: Bool {
        if case .shape = tools.tool { return true }
        return false
    }
}

// MARK: - Popovers

struct PenSettings: View {
    @EnvironmentObject var tools: ToolState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("笔型", selection: $tools.penKind) {
                Text("硬笔").tag(PenKind.pen)
                Text("毛笔").tag(PenKind.brush)
                Text("荧光笔").tag(PenKind.highlighter)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 8) {
                ForEach(ToolState.penWidths, id: \.self) { w in
                    Button { tools.penWidth = tools.penKind == .highlighter ? w * 3 : w } label: {
                        Circle().fill(Color.primary).frame(width: min(22, w + 3), height: min(22, w + 3))
                            .frame(width: 30, height: 30)
                            .background(isWidth(w) ? Color.accentColor.opacity(0.2) : .clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorSwatches(selection: $tools.penColor)
        }
        .frame(width: 250)
    }

    private func isWidth(_ w: Double) -> Bool {
        tools.penWidth == (tools.penKind == .highlighter ? w * 3 : w)
    }
}

struct ColorSwatches: View {
    @Binding var selection: RGBA
    var palette: [RGBA] = RGBA.penPalette

    var body: some View {
        HStack(spacing: 3) {
            ForEach(palette, id: \.self) { c in
                Button { selection = c } label: {
                    Circle().fill(Color(nsColor: c.nsColor))
                        .overlay(Circle().stroke(Color.gray.opacity(0.5), lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .padding(2)
                        .overlay(Circle().stroke(selection == c ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: Binding(get: { Color(nsColor: selection.nsColor) },
                                               set: { selection = RGBA(NSColor($0)) }))
                .labelsHidden()
        }
    }
}

struct EraserSettings: View {
    @ObservedObject var doc: DocumentModel
    @EnvironmentObject var tools: ToolState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tools.eraserMode) {
                ForEach(EraserMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("大小")
                Slider(value: $tools.eraserSize, in: 10...160)
            }
            Button(role: .destructive) { doc.clearInk() } label: {
                Label("清除本页笔迹", systemImage: "trash")
            }
        }
        .frame(width: 220)
    }
}

struct ShapePicker: View {
    let pick: (ShapeType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 8), spacing: 6) {
            ForEach(ShapeType.palette, id: \.self) { t in
                Button { pick(t); dismiss() } label: {
                    ShapeIcon(type: t).frame(width: 40, height: 34)
                        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(t.displayName)
            }
        }
    }
}

struct ShapeIcon: View {
    let type: ShapeType

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12)
            let spec = ShapeSpec(type: type)
            let path = Path(ShapePath.path(for: spec, in: rect))
            if !type.isOpen { ctx.fill(path, with: .color(.accentColor.opacity(0.18)), style: FillStyle(eoFill: true)) }
            ctx.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 1.4, dash: type == .dottedLine ? [3, 2] : []))
            if let heads = ShapePath.arrowHeads(for: ShapeSpec(type: type, style: ShapeAppearance(lineWidth: 1)), in: rect) {
                ctx.fill(Path(heads), with: .color(.primary))
            }
        }
    }
}

struct TablePicker: View {
    let pick: (Int, Int) -> Void
    @State private var hover = (0, 0)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 8) {
            Text(hover.0 > 0 ? "\(hover.0) 行 × \(hover.1) 列" : "插入表格").font(.caption)
            VStack(spacing: 3) {
                ForEach(1...8, id: \.self) { r in
                    HStack(spacing: 3) {
                        ForEach(1...8, id: \.self) { c in
                            Rectangle()
                                .fill(r <= hover.0 && c <= hover.1 ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.15))
                                .frame(width: 18, height: 18)
                                .onHover { if $0 { hover = (r, c) } }
                                .onTapGesture { pick(r, c); dismiss() }
                        }
                    }
                }
            }
        }
    }
}

struct SubjectTools: View {
    @ObservedObject var doc: DocumentModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("书写格").font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach([BackgroundPattern.fourLines, .tianzige, .grid, .ruled, .dots], id: \.self) { p in
                    Button(p.displayName) {
                        doc.editSlide { $0.background.pattern = p }
                        dismiss()
                    }
                }
            }
            Divider()
            Text("插入").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("拼音四线格文本") {
                    doc.insertText("pīn yīn", at: CGPoint(x: 200, y: 200), spec: TextSpec(text: "", fontName: "Helvetica", fontSize: 48))
                    dismiss()
                }
                Button("坐标轴") { insertAxes(); dismiss() }
                Button("数轴") { insertNumberLine(); dismiss() }
            }
        }
        .frame(width: 380)
    }

    private func insertAxes() {
        let style = ShapeAppearance(stroke: .black, lineWidth: 2)
        let c = CGPoint(x: doc.courseware.slideSize.width / 2, y: doc.courseware.slideSize.height / 2)
        let x = BoardElement(frame: CGRect(x: c.x - 250, y: c.y, width: 500, height: 1),
                             content: .shape(ShapeSpec(type: .lineArrowEnd, style: style)))
        let y = BoardElement(frame: CGRect(x: c.x, y: c.y - 200, width: 1, height: 400),
                             content: .shape(ShapeSpec(type: .lineArrowEnd, style: style, antiDiagonal: true)))
        let lx = BoardElement(frame: CGRect(x: c.x + 240, y: c.y + 6, width: 40, height: 36), content: .text(TextSpec(text: "x", fontSize: 26, italic: true)))
        let ly = BoardElement(frame: CGRect(x: c.x + 10, y: c.y - 215, width: 40, height: 36), content: .text(TextSpec(text: "y", fontSize: 26, italic: true)))
        let o = BoardElement(frame: CGRect(x: c.x - 30, y: c.y + 4, width: 30, height: 36), content: .text(TextSpec(text: "O", fontSize: 24, italic: true)))
        if let g = BoardElement.group([x, y, lx, ly, o]) { doc.insert(g) }
    }

    private func insertNumberLine() {
        let w = 700.0
        let left = (doc.courseware.slideSize.width - w) / 2, y = doc.courseware.slideSize.height / 2
        var parts: [BoardElement] = [BoardElement(frame: CGRect(x: left, y: y, width: w, height: 1),
                                                  content: .shape(ShapeSpec(type: .lineArrowEnd, style: ShapeAppearance(stroke: .black, lineWidth: 2))))]
        for i in 0...10 {
            let x = left + 30 + Double(i) * 62
            parts.append(BoardElement(frame: CGRect(x: x, y: y - 8, width: 1, height: 16),
                                      content: .shape(ShapeSpec(type: .line, style: ShapeAppearance(stroke: .black, lineWidth: 2)))))
            parts.append(BoardElement(frame: CGRect(x: x - 20, y: y + 12, width: 40, height: 30),
                                      content: .text(TextSpec(text: "\(i - 5)", fontSize: 20, alignment: .center))))
        }
        if let g = BoardElement.group(parts) { doc.insert(g) }
    }
}
