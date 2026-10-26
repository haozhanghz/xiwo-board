import SwiftUI
import XiwoCore

/// How much room ribbon buttons take; the editor toolbar steps down as the window narrows.
enum RibbonDensity {
    case regular, tight, iconOnly
}

private struct RibbonDensityKey: EnvironmentKey {
    static let defaultValue = RibbonDensity.regular
}

extension EnvironmentValues {
    var ribbonDensity: RibbonDensity {
        get { self[RibbonDensityKey.self] }
        set { self[RibbonDensityKey.self] = newValue }
    }
}

/// Big icon-over-label button used by the editor ribbon and presenter bar.
struct RibbonButton: View {
    let title: String
    let systemImage: String
    var active = false
    var tint: Color? = nil
    /// What VoiceOver says, when the title alone does not tell what the button does.
    var label: String? = nil
    let action: () -> Void
    @Environment(\.ribbonDensity) private var density
    @Environment(\.colorScheme) private var colorScheme

    /// Labels sit a step quieter than icons, so the row reads as a row of icons.
    private var labelColor: Color { colorScheme == .dark ? Color.white.opacity(0.7) : Theme.secondaryText }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .regular)).frame(height: 20)
                if density != .iconOnly {
                    // Even-width digits, so a ticking time does not change the button's width.
                    Text(title).font(.system(size: 10.5).monospacedDigit()).fixedSize()
                        .foregroundStyle(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(tint ?? labelColor))
                }
            }
            .frame(minWidth: density == .regular ? 44 : 32, minHeight: density == .iconOnly ? 32 : 0)
            .padding(.vertical, 4).padding(.horizontal, density == .regular ? 4 : 2)
            .foregroundStyle(active ? Theme.accent : (tint ?? Theme.text))
            .background(active ? Theme.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .help(title)
        .accessibilityLabel(label ?? title)
        .accessibilityAddTraits(active ? .isSelected : [])
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
    @FocusState private var titleFocused: Bool
    @AppStorage("InspectorShown") private var inspectorShown = false

    var body: some View {
        HStack(spacing: 2) {
            Button { app.closeDocument() } label: {
                Image(systemName: "house").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                    .frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .help("返回首页")
            .accessibilityLabel("返回首页")
            .padding(.leading, 78) // clear the traffic lights

            Rectangle().fill(Theme.line).frame(width: 1, height: 16).padding(.horizontal, 8)

            TextField("课件名称", text: Binding(get: { doc.pendingTitle ?? doc.title }, set: { doc.pendingTitle = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: min(220, max(60, CGFloat((doc.pendingTitle ?? doc.title).count) * 13.5 + 8)))
                .focused($titleFocused)
                .onSubmit { doc.finishEditing() }
                .onChange(of: titleFocused) { _, focused in if !focused { doc.finishEditing() } }

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
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 22, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(QuietButtonStyle(cornerRadius: 6))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("文件")
            .accessibilityLabel("文件菜单")
            .padding(.trailing, 12)

            // Labels shrink, then disappear, so 授课 stays visible in narrow windows.
            ViewThatFits(in: .horizontal) {
                toolButtons.environment(\.ribbonDensity, .regular)
                toolButtons.environment(\.ribbonDensity, .tight)
                toolButtons.environment(\.ribbonDensity, .iconOnly)
                ScrollView(.horizontal, showsIndicators: false) {
                    toolButtons.environment(\.ribbonDensity, .iconOnly)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, 8)

            Button { inspectorShown.toggle() } label: {
                Image(systemName: "sidebar.right").font(.system(size: 15))
                    .foregroundStyle(inspectorShown ? Theme.text : Theme.secondaryText)
                    .frame(width: 32, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle(active: inspectorShown))
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(inspectorShown ? "收起属性面板（⌥⌘I）" : "显示属性面板（⌥⌘I）")
            .accessibilityLabel(inspectorShown ? "收起属性面板" : "显示属性面板")
            .padding(.trailing, 8)

            PresentButton(app: app)
                .padding(.trailing, 14)
        }
        .frame(height: 52)
        .background(Theme.background)
    }

    private var toolButtons: some View {
        HStack(spacing: 2) {
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
        }
        .fixedSize()
    }

    private var divider: some View { Rectangle().fill(Theme.line).frame(width: 1, height: 22).padding(.horizontal, 6) }

    private var isShapeTool: Bool {
        if case .shape = tools.tool { return true }
        return false
    }
}

/// 授课: the one filled button in the editor, with a menu for where to start.
struct PresentButton: View {
    let app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Button { app.startPresentation() } label: {
                Label("授课", systemImage: "play.fill")
                    .labelStyle(PresentLabelStyle())
                    .padding(.leading, 12).padding(.trailing, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("从当前页开始授课（⌘↩）")
            Rectangle().fill(.white.opacity(0.28)).frame(width: 1, height: 16)
            Menu {
                Button("从当前页开始") { app.startPresentation() }
                Button("从第一页开始") { app.startPresentation(fromBeginning: true) }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .frame(width: 26, height: 30).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("授课选项")
        }
        .foregroundStyle(.white)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }

    private struct PresentLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                configuration.icon.font(.system(size: 10))
                configuration.title.font(.system(size: 13, weight: .semibold))
            }
        }
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
            // Stays in place for the other pens, so the popover keeps its size.
            Toggle("笔锋", isOn: $tools.penNib)
                .toggleStyle(SettingToggleStyle())
                .help("写快变细，提笔出锋")
                .disabled(tools.penKind != .pen)
            HStack(spacing: 0) {
                ForEach(ToolState.penWidths, id: \.self) { w in
                    Button { tools.penWidth = tools.penKind == .highlighter ? w * 3 : w } label: {
                        Circle().fill(Color.primary).frame(width: dotSize(w), height: dotSize(w))
                            .frame(width: 32, height: 32)
                            .background(isWidth(w) ? Theme.accent.opacity(0.18) : .clear, in: Circle())
                            // The whole cell takes the click, not just the dot: a thin pen's dot is a few points wide.
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("笔宽 \(Int(tools.penKind == .highlighter ? w * 3 : w))")
                    .accessibilityAddTraits(isWidth(w) ? .isSelected : [])
                }
            }
            ColorSwatches(selection: $tools.penColor)
        }
        .frame(width: 250)
    }

    private func isWidth(_ w: Double) -> Bool {
        tools.penWidth == (tools.penKind == .highlighter ? w * 3 : w)
    }

    /// Grows with the log of the width so the thin pens still look different from each other.
    private func dotSize(_ w: Double) -> Double { 4 + 4 * log2(w) }
}

struct ColorSwatches: View {
    @Binding var selection: RGBA
    var palette: [RGBA] = RGBA.penPalette

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 24), spacing: 2)], alignment: .leading, spacing: 4) {
            ForEach(palette, id: \.self) { c in
                Button { selection = c } label: {
                    Circle().fill(Color(nsColor: c.nsColor))
                        .overlay(Circle().strokeBorder(Theme.line))
                        .frame(width: 18, height: 18)
                        .padding(2)
                        .overlay(Circle().strokeBorder(selection == c ? Theme.text : .clear, lineWidth: 1.5))
                        .frame(minWidth: 24, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(colorName(c))
                .accessibilityAddTraits(selection == c ? .isSelected : [])
            }
            // Any other colour: a rainbow dot that opens the system colour panel.
            ZStack {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().fill(Color(nsColor: selection.nsColor)).frame(width: 9, height: 9))
                    .padding(2)
                    .overlay(Circle().strokeBorder(RGBA.penPalette.contains(selection) || palette.contains(selection)
                                                   ? .clear : Theme.text, lineWidth: 1.5))
                    .allowsHitTesting(false)
                ColorPicker("自定义颜色", selection: Binding(get: { Color(nsColor: selection.nsColor) },
                                                   set: { selection = RGBA(NSColor($0)) }))
                    .labelsHidden()
                    .opacity(0.02)
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
            }
            .frame(minWidth: 24, minHeight: 24)
            .help("自定义颜色")
        }
    }

    private func colorName(_ color: RGBA) -> String {
        let names = ["黑色", "白色", "红色", "橙色", "黄色", "绿色", "蓝色", "紫色"]
        if let index = RGBA.penPalette.firstIndex(of: color) { return names[index] }
        return "颜色 \(color.argbHex)"
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
                .accessibilityLabel(t.displayName)
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
                            // Buttons, so each size can be picked by name with VoiceOver or the keyboard.
                            Button { pick(r, c); dismiss() } label: {
                                Rectangle()
                                    .fill(r <= hover.0 && c <= hover.1 ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.15))
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { hover = (r, c) } }
                            .accessibilityLabel("插入 \(r) 行 \(c) 列的表格")
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
