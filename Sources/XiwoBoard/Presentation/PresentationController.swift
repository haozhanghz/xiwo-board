import AppKit
import Combine
import QuartzCore
import SwiftUI
import XiwoCore

/// Full-screen lecture mode (授课): the board fills the screen and the tools
/// live in separate floating panels so they can be hidden, or left out of a
/// lecture recording, without touching the courseware itself.
@MainActor
final class PresentationController: NSObject, ObservableObject, NSWindowDelegate {
    let document: DocumentModel
    let tools: ToolState
    let recorder: LectureRecorder
    var onClose: (() -> Void)?

    /// Tool panels are on screen (隐藏功能页面 turns this off).
    @Published var chromeVisible = true { didSet { layoutChrome() } }
    /// Compact toolbar with only the essentials (简单工具栏).
    @Published var simpleToolbar = false { didSet { layoutChrome() } }
    @Published var showPages = false { didSet { layoutChrome() } }
    @Published var showTimer = false { didSet { layoutChrome() } }
    @Published private(set) var isEnding = false

    /// Settings panels opened from the toolbar (笔、橡皮、形状、录制).
    enum Flyout: Hashable { case pen, eraser, shape, record }
    @Published private(set) var flyout: Flyout?
    /// Toolbar button frames, in the toolbar's own coordinates, to place flyouts above them.
    var flyoutAnchors: [Flyout: CGRect] = [:]

    private var window: NSWindow!
    private var canvas: BoardCanvasView!
    private var toolbarPanel: NSPanel!
    private var handlePanel: NSPanel!
    private var pagesPanel: NSPanel?
    private var timerPanel: NSPanel?
    private var flyoutPanel: NSPanel?
    private var flyoutClosedAt: (Flyout, Date)?
    private var mouseMonitor: Any?
    private var startSnapshot: Courseware
    private var lastIndex: Int
    private var cancellables: Set<AnyCancellable> = []
    private var savedTool: Tool
    private var autoPlayTask: Task<Void, Never>?

    init(document: DocumentModel, tools: ToolState, recorder: LectureRecorder) {
        self.document = document
        self.tools = tools
        self.recorder = recorder
        self.startSnapshot = document.courseware
        self.lastIndex = document.currentIndex
        self.savedTool = tools.tool
        super.init()
    }

    var chromeWindows: [NSWindow] { [toolbarPanel, handlePanel, pagesPanel, timerPanel, flyoutPanel].compactMap { $0 } }

    func show() {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let w = PresenterWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: true)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        w.delegate = self
        window = w

        let c = BoardCanvasView(document: document, tools: tools, mode: .present)
        c.onHyperlink = { [weak self] link in self?.follow(link) }
        c.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        c.onPlayMedia = { [weak self] e in
            guard let self else { return }
            MediaPlayerOverlay.play(e, document: self.document, in: self.canvas)
        }
        c.wantsLayer = true
        w.contentView = c
        canvas = c

        toolbarPanel = makePanel(PresentationToolbar(presenter: self, maxWidth: screen.frame.width - 24)
            .environmentObject(tools).environmentObject(recorder))
        handlePanel = makePanel(ChromeHandle(presenter: self))

        tools.tool = .pen
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(c)
        layoutChrome()

        document.$currentIndex.removeDuplicates().sink { [weak self] i in
            DispatchQueue.main.async { self?.pageChanged(to: i) }
        }.store(in: &cancellables)
        recorder.$state.sink { [weak self] _ in DispatchQueue.main.async { self?.layoutChrome() } }.store(in: &cancellables)
        // A click anywhere outside the open flyout closes it.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self, let open = self.flyout, e.window !== self.flyoutPanel {
                self.flyoutClosedAt = (open, Date())
                self.closeFlyout()
            }
            return e
        }
        autoPlayMedia()
    }

    private func makePanel<V: View>(_ view: V) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        let host = NSHostingView(rootView: view)
        p.contentView = host
        return p
    }

    /// Positions and shows/hides the tool panels.
    func layoutChrome() {
        guard !isEnding, let window, let screen = window.screen else { return }
        let frame = screen.frame
        let fitting = toolbarPanel.contentView!.fittingSize
        // Rounded up so the layout the toolbar measured with still fits once placed.
        let toolbarSize = NSSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
        toolbarPanel.setContentSize(toolbarSize)
        toolbarPanel.setFrameOrigin(NSPoint(x: frame.midX - toolbarSize.width / 2, y: frame.minY + 18))
        let hs = handlePanel.contentView!.fittingSize
        handlePanel.setContentSize(hs)
        handlePanel.setFrameOrigin(NSPoint(x: frame.maxX - hs.width - 18, y: frame.minY + 18))
        setVisible(toolbarPanel, chromeVisible)
        setVisible(handlePanel, !chromeVisible)

        if showPages && chromeVisible {
            if pagesPanel == nil {
                pagesPanel = makePanel(PageGrid(doc: document) { [weak self] in self?.showPages = false })
            }
            let size = NSSize(width: min(frame.width - 120, 980), height: min(frame.height - 200, 560))
            pagesPanel!.setContentSize(size)
            pagesPanel!.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 110))
            setVisible(pagesPanel!, true)
        } else if let pagesPanel { setVisible(pagesPanel, false) }

        if showTimer && chromeVisible {
            if timerPanel == nil {
                let p = makePanel(TimerView { [weak self] in self?.showTimer = false })
                p.isMovableByWindowBackground = true
                let s = p.contentView!.fittingSize
                p.setContentSize(s)
                p.setFrameOrigin(NSPoint(x: frame.maxX - s.width - 40, y: frame.maxY - s.height - 40))
                timerPanel = p
            }
            setVisible(timerPanel!, true)
        } else if let timerPanel { setVisible(timerPanel, false) }

        if chromeVisible { positionFlyout() } else { closeFlyout() }
        recorder.refreshFilter()
    }

    // MARK: Flyouts

    // SwiftUI popovers attached to the non-activating toolbar panel close on the
    // first click without running the button inside, so the toolbar opens its
    // settings in a panel of its own instead.
    func toggleFlyout(_ kind: Flyout) {
        // The mouse-down that reached the toolbar already closed this flyout.
        if let closed = flyoutClosedAt, closed.0 == kind, Date().timeIntervalSince(closed.1) < 0.5 {
            flyoutClosedAt = nil
            return
        }
        if flyout == kind { closeFlyout() } else { openFlyout(kind) }
    }

    func openFlyout(_ kind: Flyout) {
        closeFlyout()
        let content: AnyView
        switch kind {
        case .pen: content = AnyView(PenSettings())
        case .eraser: content = AnyView(EraserSettings(doc: document))
        case .shape: content = AnyView(ShapePicker { [weak self] in self?.tools.tool = .shape($0); self?.closeFlyout() })
        case .record: content = AnyView(RecordingOptions(presenter: self))
        }
        let view = content
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15)))
            .environment(\.colorScheme, .dark)
            .environmentObject(tools)
            .environmentObject(recorder)
            .padding(4)
            .fixedSize()
        flyoutPanel = makePanel(view)
        flyout = kind
        positionFlyout()
        setVisible(flyoutPanel!, true)
    }

    func closeFlyout() {
        if let p = flyoutPanel {
            window.removeChildWindow(p)
            p.orderOut(nil)
            p.contentView = nil
            p.close()
            flyoutPanel = nil
        }
        if flyout != nil { flyout = nil }
    }

    private func positionFlyout() {
        guard let p = flyoutPanel, let kind = flyout, let screen = window.screen else { return }
        let size = p.contentView!.fittingSize
        p.setContentSize(size)
        let bar = toolbarPanel.frame
        let anchorX = flyoutAnchors[kind].map { bar.minX + $0.midX } ?? bar.midX
        let x = min(max(anchorX - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        p.setFrameOrigin(NSPoint(x: x, y: bar.maxY + 6))
    }

    private func setVisible(_ panel: NSPanel, _ visible: Bool) {
        if visible {
            if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
        } else {
            window.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    // MARK: Navigation

    func next() {
        if document.currentIndex < document.slideCount - 1 { document.go(to: document.currentIndex + 1) } else { NSSound.beep() }
    }

    func previous() {
        if document.currentIndex > 0 { document.go(to: document.currentIndex - 1) } else { NSSound.beep() }
    }

    private func pageChanged(to index: Int) {
        guard !isEnding, index != lastIndex else { return }
        let forward = index > lastIndex
        lastIndex = index
        MediaPlayerOverlay.stop()
        if let layer = canvas.layer, document.slide.transition != .none {
            let t = CATransition()
            t.duration = 0.35
            switch document.slide.transition {
            case .fade: t.type = .fade
            case .push: t.type = .push; t.subtype = forward ? .fromRight : .fromLeft
            case .reveal: t.type = .reveal; t.subtype = forward ? .fromRight : .fromLeft
            case .none: break
            }
            layer.add(t, forKey: "page")
        }
        canvas.invalidateCache()
        autoPlayMedia()
    }

    private func autoPlayMedia() {
        autoPlayTask?.cancel()
        let slideID = document.slide.id
        guard let e = document.slide.elements.first(where: {
            if case .media(let m) = $0.content { return m.autoPlay } else { return false }
        }) else { return }
        autoPlayTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            guard let self, !self.isEnding, self.document.slide.id == slideID else { return }
            MediaPlayerOverlay.play(e, document: self.document, in: self.canvas)
        }
    }

    private func follow(_ link: String) {
        let pagePrefixes = ["页面:", "页面：", "slide:", "page:"]
        if let prefix = pagePrefixes.first(where: { link.hasPrefix($0) }), let n = Int(link.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)) {
            document.go(to: n - 1)
        } else if let url = URL(string: link.contains("://") ? link : "https://" + link) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 板中板: a blank board inserted after the current page.
    func insertBlankBoard() {
        document.addSlide(after: document.currentIndex, background: SlideBackground())
        document.editSlide { $0.name = "板中板" }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 124, 125, 49, 121: next(); return true       // → ↓ space pagedown
        case 123, 126, 116: previous(); return true        // ← ↑ pageup
        case 53:                                           // esc
            if flyout != nil { closeFlyout() } else if !chromeVisible { chromeVisible = true } else { end() }
            return true
        default:
            break
        }
        let key = e.charactersIgnoringModifiers?.lowercased()
        if e.modifierFlags.contains(.command) {
            guard key == "z" else { return false }
            e.modifierFlags.contains(.shift) ? document.redo() : document.undo()
            return true
        }
        // Letter keys work alone (tablet express keys send them too); ⌃/⌥ combos are not ours.
        guard e.modifierFlags.isDisjoint(with: [.control, .option]) else { return false }
        switch key {
        case "h": chromeVisible.toggle(); return true
        case "p": tools.tool = .pen; return true
        // Toggles, so one key (or one tablet button) switches between eraser and pen.
        case "e": tools.tool = tools.tool == .eraser ? .pen : .eraser; return true
        case "c": document.clearInk(); return true   // clear this page's ink; ⌘Z brings it back
        case "l": tools.tool = .laser; return true
        case "v": tools.tool = .select; return true
        default: return false
        }
    }

    // MARK: Recording

    func toggleRecording() {
        guard !isEnding else { return }
        Task { [weak self] in
            guard let self, !self.isEnding else { return }
            if self.recorder.isRecording {
                await self.recorder.stop()
            } else {
                await self.recorder.start(window: self.window, title: self.document.title) { [weak self] in self?.chromeWindows ?? [] }
            }
        }
    }

    func togglePause() {
        guard !isEnding else { return }
        Task { [weak self] in
            guard let self, !self.isEnding else { return }
            if self.recorder.isPaused {
                await self.recorder.resume()
            } else {
                await self.recorder.pause()
            }
        }
    }

    // MARK: End

    func end() {
        guard !isEnding else { return }
        isEnding = true
        autoPlayTask?.cancel()
        Task {
            await recorder.stop()
            finishEnd()
        }
    }

    private func finishEnd() {
        MediaPlayerOverlay.stop()
        let changed = document.courseware.slides != startSnapshot.slides
        chromeWindows.forEach { $0.orderOut(nil) }
        window.orderOut(nil)
        NSApp.presentationOptions = []
        if changed {
            let a = NSAlert()
            a.messageText = "保留授课时的板书吗？"
            a.informativeText = "授课时写下的笔迹和改动可以保存到课件中。"
            a.addButton(withTitle: "保留")
            a.addButton(withTitle: "不保留")
            if a.runModal() == .alertSecondButtonReturn {
                let snap = startSnapshot
                document.edit { $0 = snap }
            }
        }
        tools.tool = savedTool == .laser || savedTool == .spotlight || savedTool == .magnifier ? .select : savedTool
        cancellables.removeAll()
        closeFlyout()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        // Hosting views retain the presenter through @ObservedObject. Break
        // those cycles so each lecture releases its panels and document snapshot.
        for panel in chromeWindows {
            window.removeChildWindow(panel)
            panel.contentView = nil
            panel.close()
        }
        toolbarPanel = nil
        handlePanel = nil
        pagesPanel = nil
        timerPanel = nil
        window.close()
        window.contentView = nil
        canvas = nil
        onClose?()
        onClose = nil
    }

    func windowDidResignKey(_ notification: Notification) {}
}

/// Borderless windows refuse key status by default; the presenter needs keys.
final class PresenterWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Toolbar

struct PresentationToolbar: View {
    @ObservedObject var presenter: PresentationController
    @ObservedObject var doc: DocumentModel
    @EnvironmentObject var tools: ToolState
    @EnvironmentObject var recorder: LectureRecorder
    let maxWidth: CGFloat

    init(presenter: PresentationController, maxWidth: CGFloat) {
        self.presenter = presenter
        self.doc = presenter.document
        self.maxWidth = maxWidth
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(buttons.environment(\.ribbonDensity, .regular))
            bar(buttons.environment(\.ribbonDensity, .tight))
            bar(buttons.environment(\.ribbonDensity, .iconOnly))
            bar(ScrollView(.horizontal, showsIndicators: true) {
                buttons.environment(\.ribbonDensity, .iconOnly)
            })
        }
        // Only caps the width on narrow screens. Each layout carries its own background
        // and the scrolling one has no fixed width, so on a wide screen the panel stays
        // as wide as the buttons instead of stretching across the screen.
        .frame(maxWidth: maxWidth)
        .environment(\.colorScheme, .dark)
        .padding(4)
        .fixedSize(horizontal: false, vertical: true)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(FlyoutAnchorKey.self) { presenter.flyoutAnchors = $0 }
        .disabled(presenter.isEnding)
    }

    private func bar(_ content: some View) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15)))
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            RibbonButton(title: "结束授课", systemImage: "xmark.circle", tint: .red) { presenter.end() }
            sep
            RibbonButton(title: "选择", systemImage: "cursorarrow", active: tools.tool == .select) { tools.tool = .select }
            flyoutButton(.pen, title: "笔", systemImage: "pencil.tip", active: tools.tool == .pen) {
                if tools.tool == .pen { presenter.toggleFlyout(.pen) } else { tools.tool = .pen }
            }
            flyoutButton(.eraser, title: "橡皮", systemImage: "eraser", active: tools.tool == .eraser) {
                if tools.tool == .eraser { presenter.toggleFlyout(.eraser) } else { tools.tool = .eraser }
            }
            RibbonButton(title: "撤消", systemImage: "arrow.uturn.backward") { doc.undo() }.disabled(!doc.canUndo)
            RibbonButton(title: "恢复", systemImage: "arrow.uturn.forward") { doc.redo() }.disabled(!doc.canRedo)
            if !presenter.simpleToolbar {
                sep
                RibbonButton(title: "激光笔", systemImage: "light.max", active: tools.tool == .laser) { tools.tool = .laser }
                RibbonButton(title: "聚光灯", systemImage: "flashlight.on.fill", active: tools.tool == .spotlight) { tools.tool = .spotlight }
                RibbonButton(title: "放大镜", systemImage: "plus.magnifyingglass", active: tools.tool == .magnifier) { tools.tool = .magnifier }
                RibbonButton(title: "计时器", systemImage: "timer", active: presenter.showTimer) { presenter.showTimer.toggle() }
                RibbonButton(title: "板中板", systemImage: "rectangle.badge.plus") { presenter.insertBlankBoard() }
                flyoutButton(.shape, title: "形状", systemImage: "square.on.circle", active: isShape) { presenter.toggleFlyout(.shape) }
            }
            sep
            recordButton
            if recorder.isRecording {
                RibbonButton(title: recorder.isPaused ? "继续" : "暂停",
                             systemImage: recorder.isPaused ? "play.circle" : "pause.circle",
                             active: recorder.isPaused) { presenter.togglePause() }
                    .help(recorder.isPaused ? "继续录制" : "暂停录制，暂停的时间不会录进视频")
            }
            RibbonButton(title: "隐藏工具", systemImage: "eye.slash") { presenter.chromeVisible = false }
                .help("隐藏全部工具，只显示课件（H 键或右下角按钮恢复）")
            RibbonButton(title: presenter.simpleToolbar ? "普通工具栏" : "简单工具栏",
                         systemImage: presenter.simpleToolbar ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
                presenter.simpleToolbar.toggle()
            }
            sep
            RibbonButton(title: "上一页", systemImage: "chevron.left") { presenter.previous() }
                .disabled(doc.currentIndex == 0)
            Button { presenter.showPages.toggle() } label: {
                Text("\(doc.currentIndex + 1)/\(doc.slideCount)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 52, minHeight: 40)
                    .background(presenter.showPages ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("页面列表")
            .accessibilityLabel("页面列表，第 \(doc.currentIndex + 1) 页，共 \(doc.slideCount) 页")
            RibbonButton(title: "下一页", systemImage: "chevron.right") { presenter.next() }
                .disabled(doc.currentIndex == doc.slideCount - 1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .fixedSize()
    }

    private static let space = "presentation-toolbar"

    private var sep: some View { Divider().frame(height: 32).padding(.horizontal, 2) }

    private func flyoutButton(_ kind: PresentationController.Flyout, title: String, systemImage: String, active: Bool,
                              action: @escaping () -> Void) -> some View {
        RibbonButton(title: title, systemImage: systemImage, active: active || presenter.flyout == kind, action: action)
            .background(GeometryReader { g in
                Color.clear.preference(key: FlyoutAnchorKey.self, value: [kind: g.frame(in: .named(Self.space))])
            })
    }

    private var isShape: Bool { if case .shape = tools.tool { return true } else { return false } }

    /// Opens the recording options while idle; stops straight away while recording or paused.
    private var recordButton: some View {
        let title: String
        switch recorder.state {
        case .idle: title = "录制"
        case .starting: title = "准备中"
        case .recording, .paused: title = LectureRecorder.format(recorder.elapsed)
        case .stopping: title = "保存中"
        }
        return flyoutButton(.record, title: title, systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle",
                            active: recorder.isRecording) {
            switch recorder.state {
            case .idle: presenter.toggleFlyout(.record)
            case .recording, .paused: presenter.toggleRecording()
            case .starting, .stopping: break
            }
        }
        .foregroundStyle(recorder.isRecording ? .red : .primary)
        .help(recorder.isRecording ? "停止录制" : "录屏讲课")
    }
}

private struct FlyoutAnchorKey: PreferenceKey {
    static let defaultValue: [PresentationController.Flyout: CGRect] = [:]
    static func reduce(value: inout [PresentationController.Flyout: CGRect], nextValue: () -> [PresentationController.Flyout: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct RecordingOptions: View {
    @ObservedObject var presenter: PresentationController
    @EnvironmentObject var recorder: LectureRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("录屏讲课").font(.headline)
            Toggle("只录课件（隐藏工具栏、计时器等功能页面）", isOn: $recorder.coursewareOnly)
            Toggle("录制麦克风", isOn: $recorder.recordMicrophone).disabled(recorder.state != .idle)
            Toggle("录制电脑声音", isOn: $recorder.recordSystemAudio).disabled(recorder.state != .idle)
            Toggle("录制鼠标指针", isOn: $recorder.recordCursor).disabled(recorder.state != .idle)
            Text("视频保存在「影片 › XiwoBoard 录课」。录制中点「暂停」可以暂停，暂停的时间不会录进视频；再点一次「录制」按钮即可停止。不录鼠标指针时，可以用激光笔在视频里指示。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    presenter.closeFlyout()
                    presenter.toggleRecording()
                } label: {
                    Label("开始录制", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(recorder.state != .idle)
                if let last = recorder.lastRecording {
                    Button("打开上次录制") { NSWorkspace.shared.open(last) }
                }
            }
        }
        .frame(width: 320)
    }
}

/// Small button left on screen while the tools are hidden.
struct ChromeHandle: View {
    @ObservedObject var presenter: PresentationController
    @ObservedObject var recorder: LectureRecorder

    init(presenter: PresentationController) {
        self.presenter = presenter
        self.recorder = presenter.recorder
    }

    var body: some View {
        HStack(spacing: 6) {
            if recorder.isRecording {
                Circle().fill(recorder.isPaused ? .orange : .red).frame(width: 8, height: 8)
                Text(LectureRecorder.format(recorder.elapsed)).font(.caption.monospacedDigit())
                Button { presenter.togglePause() } label: {
                    Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill").font(.system(size: 13))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(recorder.isPaused ? "继续录制" : "暂停录制")
                .accessibilityLabel(recorder.isPaused ? "继续录制" : "暂停录制")
            }
            Button { presenter.chromeVisible = true } label: {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .help("显示工具栏（H）")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .opacity(0.75)
        .padding(4)
        .fixedSize()
    }
}

struct PageGrid: View {
    @ObservedObject var doc: DocumentModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("页面").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(12)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    ForEach(Array(doc.courseware.slides.enumerated()), id: \.element.id) { i, s in
                        Button { doc.go(to: i); close() } label: {
                            VStack(spacing: 4) {
                                SlidePreview(slide: s, courseware: doc.courseware, pixelWidth: 300)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(i == doc.currentIndex ? Color.accentColor : .clear, lineWidth: 3))
                                Text("\(i + 1)").font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
    }
}
