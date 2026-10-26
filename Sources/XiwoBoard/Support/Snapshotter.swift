import AVFoundation
import AppKit
import SwiftUI
import XiwoCore

/// `XiwoBoard --snapshot <dir>` renders the main screens to PNGs offscreen and
/// quits. Used to check the UI on machines without screen-recording access.
@MainActor
enum Snapshotter {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                run(into: dir)
                exit(0)
            }
        }
        return true
    }

    static func run(into dir: URL) {
        let app = AppModel.shared
        let doc = DocumentModel(courseware: SampleCourseware.make())
        app.document = doc
        doc.go(to: 1)
        doc.selection = [doc.slide.elements[1].id]

        render(HomeView().environmentObject(app).environmentObject(app.tools), size: CGSize(width: 1280, height: 800),
               to: dir.appendingPathComponent("home.png"))
        // The start page with a few recent files, without touching the real recent list for long.
        let savedRecent = UserDefaults.standard.stringArray(forKey: "recentFiles")
        let samples = ["一年级数学 认识图形", "三年级语文 古诗两首", "拼音复习 第三单元"].map { dir.appendingPathComponent("\($0).xwb") }
        for url in samples { try? CoursewareArchive.encode(doc.courseware).write(to: url) }
        UserDefaults.standard.set(samples.map(\.path), forKey: "recentFiles")
        render(HomeView().environmentObject(app).environmentObject(app.tools), size: CGSize(width: 1280, height: 800),
               to: dir.appendingPathComponent("home-recents.png"))
        // The pointer on the second recent file: the list's one highlight sits there, its hairlines gone.
        if RecentFiles.urls.count > 1 {
            render(HomeView().environmentObject(app).environmentObject(app.tools)
                    .environment(\.fluidHoverPreview, AnyHashable(RecentFiles.urls[1])),
                   size: CGSize(width: 1280, height: 800), to: dir.appendingPathComponent("home-hover.png"))
        }
        UserDefaults.standard.set(savedRecent, forKey: "recentFiles")
        for url in samples { try? FileManager.default.removeItem(at: url) }
        render(EditorView(doc: doc).environmentObject(app).environmentObject(app.tools), size: CGSize(width: 1440, height: 900),
               to: dir.appendingPathComponent("editor.png"))
        // With the property panel open, as when an object is being styled.
        let inspectorWasShown = UserDefaults.standard.bool(forKey: "InspectorShown")
        UserDefaults.standard.set(true, forKey: "InspectorShown")
        render(EditorView(doc: doc).environmentObject(app).environmentObject(app.tools), size: CGSize(width: 1440, height: 900),
               to: dir.appendingPathComponent("editor-inspector.png"))
        // Nothing selected: the panel shows the page's background, grid and notes.
        let selection = doc.selection
        doc.selection = []
        render(EditorView(doc: doc).environmentObject(app).environmentObject(app.tools), size: CGSize(width: 1440, height: 900),
               to: dir.appendingPathComponent("editor-page.png"))
        doc.selection = selection
        UserDefaults.standard.set(inspectorWasShown, forKey: "InspectorShown")
        // Dark mode, with the app's appearance switched for the moment.
        let appearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        render(HomeView().environmentObject(app).environmentObject(app.tools).environment(\.colorScheme, .dark),
               size: CGSize(width: 1280, height: 800), to: dir.appendingPathComponent("home-dark.png"))
        render(EditorView(doc: doc).environmentObject(app).environmentObject(app.tools).environment(\.colorScheme, .dark),
               size: CGSize(width: 1440, height: 900), to: dir.appendingPathComponent("editor-dark.png"))
        NSApp.appearance = appearance
        // In a window like the app's own, so the window buttons show beside the toolbar.
        renderWindow(EditorView(doc: doc).environmentObject(app).environmentObject(app.tools), size: CGSize(width: 1440, height: 900),
                     to: dir.appendingPathComponent("editor-window.png"))
        renderWindow(HomeView().environmentObject(app).environmentObject(app.tools), size: CGSize(width: 1280, height: 800),
                     to: dir.appendingPathComponent("home-window.png"))
        // The narrowest window the app allows, and a smaller one that needs icon-only tools.
        render(EditorView(doc: doc).environmentObject(app).environmentObject(app.tools), size: CGSize(width: 1000, height: 640),
               to: dir.appendingPathComponent("editor-1000.png"))
        render(EditorToolbar(doc: doc).environmentObject(app).environmentObject(app.tools), size: CGSize(width: 820, height: 60),
               to: dir.appendingPathComponent("toolbar-820.png"))
        // The pointer on 画笔 while 选择 is the chosen tool.
        render(EditorToolbar(doc: doc).environmentObject(app).environmentObject(app.tools).environment(\.fluidHoverPreview, "画笔"),
               size: CGSize(width: 1440, height: 52), to: dir.appendingPathComponent("toolbar-hover.png"))

        let presenter = PresentationController(document: doc, tools: app.tools, recorder: app.recorder)
        render(PresentationToolbar(presenter: presenter, maxWidth: 1900).environmentObject(app.tools).environmentObject(app.recorder),
               size: nil, to: dir.appendingPathComponent("present-toolbar.png"))
        render(PresentationToolbar(presenter: presenter, maxWidth: 1000).environmentObject(app.tools).environmentObject(app.recorder),
               size: nil, to: dir.appendingPathComponent("present-toolbar-1000.png"))
        render(PresentationToolbar(presenter: presenter, maxWidth: 1900).environmentObject(app.tools).environmentObject(app.recorder)
                .environment(\.fluidHoverPreview, "激光笔"),
               size: nil, to: dir.appendingPathComponent("present-toolbar-hover.png"))
        // While recording, and while paused, the toolbar and the handle carry a pause button.
        for (state, name) in [(LectureRecorder.State.recording, "recording"), (.paused, "paused")] {
            app.recorder.preview(state, elapsed: 754)
            render(PresentationToolbar(presenter: presenter, maxWidth: 1900).environmentObject(app.tools).environmentObject(app.recorder),
                   size: nil, to: dir.appendingPathComponent("present-toolbar-\(name).png"))
            render(ChromeHandle(presenter: presenter), size: nil, to: dir.appendingPathComponent("handle-\(name).png"))
        }
        app.recorder.preview(.idle, elapsed: 0)
        render(RecordingOptions(presenter: presenter).environmentObject(app.recorder).padding(14)
                .background(Color(white: 0.2)).environment(\.colorScheme, .dark),
               size: nil, to: dir.appendingPathComponent("record-options.png"))
        Updater.shared.preview(Updater.Release(version: "9.9.9", notes: "## 新功能\n\n- **录屏**修复\n- 应用内更新\n\n普通段落文字。",
                                               page: URL(string: "https://github.com")!,
                                               archive: .init(name: "x.zip", apiURL: URL(string: "https://github.com")!), checksum: nil))
        render(UpdateView().environmentObject(Updater.shared), size: nil, to: dir.appendingPathComponent("update.png"))
        render(TimerView {}, size: nil, to: dir.appendingPathComponent("timer.png"))
        render(ShapePicker { _ in }.padding(12).background(Color(nsColor: .windowBackgroundColor)), size: nil,
               to: dir.appendingPathComponent("shapes.png"))
        render(PenSettings().environmentObject(app.tools).padding(14).background(Color(nsColor: .windowBackgroundColor)), size: nil,
               to: dir.appendingPathComponent("pen-settings.png"))
        render(TablePicker { _, _ in }.padding(12).background(Color(nsColor: .windowBackgroundColor)), size: nil,
               to: dir.appendingPathComponent("table-picker.png"))
        // An audio object at its default size, in a canvas about as large as the editor's.
        let bar = AudioPlayerBar(player: AVPlayer(), name: "示例音频")
        bar.place(over: NSRect(x: 230, y: 150, width: 140, height: 90), in: NSRect(x: 0, y: 0, width: 600, height: 400))
        render(bar, to: dir.appendingPathComponent("audio-player.png"))

        for (i, s) in doc.courseware.slides.enumerated() {
            if let img = SlideRenderer.image(of: s, courseware: doc.courseware, pixelWidth: 1280),
               let png = Exporter.pngData(img) {
                try? png.write(to: dir.appendingPathComponent("slide-\(i + 1).png"))
            }
        }
        try? SlideRenderer.pdf(of: doc.courseware).write(to: dir.appendingPathComponent("sample.pdf"))
        try? CoursewareArchive.encode(doc.courseware).write(to: dir.appendingPathComponent("示例课件.xwb"))
        try? EnbxExporter.encode(doc.courseware).write(to: dir.appendingPathComponent("示例课件.enbx"))
    }

    static func render(_ view: NSView, to url: URL) {
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: view.bounds)
        view.frame.origin = .zero
        host.addSubview(view)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Renders a view in a titled window with a hidden title bar, as the main window is, title bar included.
    static func renderWindow<V: View>(_ view: V, size: CGSize, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: view.mainWindowChrome())
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let frame = window.contentView?.superview else { return }
        frame.layoutSubtreeIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func render<V: View>(_ view: V, size: CGSize?, to url: URL) {
        let host = NSHostingView(rootView: view)
        let s = size ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: s), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: s)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// A short demo lesson that exercises most element kinds.
enum SampleCourseware {
    static func make() -> Courseware {
        var cw = Courseware(title: "示例：认识图形")
        var cover = Slide(background: SlideBackground(color: .chalkboard, patternColor: RGBA(1, 1, 1, 0.3)))
        cover.elements = [
            BoardElement(frame: CGRect(x: 240, y: 230, width: 800, height: 110),
                         content: .text(TextSpec(text: "认识图形", fontSize: 84, color: .white, bold: true, alignment: .center))),
            BoardElement(frame: CGRect(x: 340, y: 360, width: 600, height: 60),
                         content: .text(TextSpec(text: "一年级 数学 · 第三单元", fontSize: 32, color: RGBA(0.85, 0.95, 0.88), alignment: .center))),
            .stroke(points: (0...60).map { i in StrokePoint(x: 420 + Double(i) * 7, y: 450 + sin(Double(i) / 6) * 8) },
                    color: .yellow, width: 6, kind: .pen),
        ]
        var shapes = Slide()
        shapes.elements = [
            BoardElement(frame: CGRect(x: 80, y: 50, width: 700, height: 70),
                         content: .text(TextSpec(text: "说一说：这些是什么图形？", fontSize: 44, bold: true))),
            BoardElement(frame: CGRect(x: 110, y: 180, width: 220, height: 160),
                         content: .shape(ShapeSpec(type: .rectangle, style: ShapeAppearance(stroke: .blue, fill: RGBA(0.13, 0.45, 0.95, 0.2), lineWidth: 5)))),
            BoardElement(frame: CGRect(x: 420, y: 170, width: 190, height: 190),
                         content: .shape(ShapeSpec(type: .circle, style: ShapeAppearance(stroke: .red, fill: RGBA(0.92, 0.2, 0.2, 0.2), lineWidth: 5)))),
            BoardElement(frame: CGRect(x: 700, y: 170, width: 220, height: 190),
                         content: .shape(ShapeSpec(type: .triangle, style: ShapeAppearance(stroke: .green, fill: RGBA(0.13, 0.7, 0.35, 0.2), lineWidth: 5)))),
            BoardElement(frame: CGRect(x: 1000, y: 170, width: 200, height: 190),
                         content: .shape(ShapeSpec(type: .star, style: ShapeAppearance(stroke: RGBA(1, 0.55, 0), fill: RGBA(1, 0.82, 0.1, 0.5), lineWidth: 5)))),
            BoardElement(frame: CGRect(x: 110, y: 380, width: 220, height: 50), masked: true,
                         content: .text(TextSpec(text: "长方形", fontSize: 36, alignment: .center))),
            BoardElement(frame: CGRect(x: 405, y: 380, width: 220, height: 50), masked: true,
                         content: .text(TextSpec(text: "圆", fontSize: 36, alignment: .center))),
            BoardElement(frame: CGRect(x: 700, y: 380, width: 220, height: 50), masked: true,
                         content: .text(TextSpec(text: "三角形", fontSize: 36, alignment: .center))),
            BoardElement(frame: CGRect(x: 990, y: 380, width: 220, height: 50), masked: true,
                         content: .text(TextSpec(text: "五角星", fontSize: 36, alignment: .center))),
            .stroke(points: (0...40).map { i in StrokePoint(x: 120 + Double(i) * 5, y: 560 - Double(i % 20) * 3, pressure: 0.5 + Double(i % 10) / 20) },
                    color: .red, width: 10, kind: .brush),
            .stroke(points: [StrokePoint(x: 420, y: 560), StrokePoint(x: 820, y: 560)], color: .yellow, width: 24, kind: .highlighter),
            BoardElement(frame: CGRect(x: 420, y: 530, width: 420, height: 56),
                         content: .text(TextSpec(text: "点击蓝色蒙层揭晓答案", fontSize: 30))),
        ]
        var practice = Slide(background: SlideBackground(pattern: .fourLines, patternColor: RGBA(0.85, 0.3, 0.3)))
        var table = TableSpec(rows: 3, columns: 4)
        table.cells = [["图形", "边", "角", "例子"], ["三角形", "3", "3", "三角尺"], ["长方形", "4", "4", "黑板"]]
        practice.elements = [
            BoardElement(frame: CGRect(x: 160, y: 470, width: 960, height: 190), content: .table(table)),
            BoardElement(frame: CGRect(x: 60, y: 40, width: 600, height: 64), content: .text(TextSpec(text: "sān jiǎo xíng", fontName: "Helvetica", fontSize: 48))),
            BoardElement(frame: CGRect(x: 900, y: 120, width: 240, height: 120), cloneOnDrag: true,
                         content: .shape(ShapeSpec(type: .roundRectangle, style: ShapeAppearance(stroke: .blue, fill: RGBA(0.9, 0.95, 1), lineWidth: 3), text: "拖我复制"))),
        ]
        var grid = Slide(background: SlideBackground(pattern: .tianzige, patternColor: RGBA(0.2, 0.6, 0.3)))
        grid.elements = ShapeType.palette.prefix(12).enumerated().map { i, t in
            BoardElement(frame: CGRect(x: 60 + Double(i % 6) * 200, y: 60 + Double(i / 6) * 250, width: 150, height: 110),
                         content: .shape(ShapeSpec(type: t, style: ShapeAppearance(stroke: .black, fill: t.isOpen ? nil : RGBA(0.13, 0.45, 0.95, 0.15), lineWidth: 3))))
        }
        cw.slides = [cover, shapes, practice, grid]
        return cw
    }
}
