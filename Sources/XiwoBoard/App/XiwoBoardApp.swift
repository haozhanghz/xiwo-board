import AppKit
import SwiftUI
import XiwoCore

@main
struct XiwoBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        WindowGroup("XiwoBoard") {
            RootView()
                .environmentObject(app)
                .environmentObject(app.tools)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(app: app) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if MainActor.assumeIsolated({ Snapshotter.runIfRequested() }) { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await Updater.shared.checkOnLaunch()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let url = urls.first { AppModel.shared.open(url) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let app = AppModel.shared
            return app.skipQuitConfirmation || app.confirmClose() ? .terminateNow : .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// App-wide state: the open document, tools, and presentation.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var document: DocumentModel?
    let tools = ToolState()
    let recorder = LectureRecorder()
    private(set) var presenter: PresentationController?
    /// Set once unsaved changes were already handled, e.g. before relaunching into an update.
    var skipQuitConfirmation = false

    func newDocument(background: SlideBackground = SlideBackground()) {
        guard confirmClose() else { return }
        document = DocumentModel(courseware: Courseware(slides: [Slide(background: background)]))
    }

    func openWithPanel() {
        guard let url = Exporter.chooseCourseware() else { return }
        open(url)
    }

    func open(_ url: URL) {
        guard confirmClose() else { return }
        do {
            let (doc, warnings) = try DocumentModel.open(url: url)
            document = doc
            if !warnings.isEmpty {
                let a = NSAlert()
                a.messageText = "课件已导入"
                let unique = Array(Set(warnings)).sorted()
                a.informativeText = "部分内容暂不支持，已跳过：\n" + unique.prefix(8).joined(separator: "\n")
                a.runModal()
            }
        } catch {
            RecentFiles.remove(url)
            Exporter.showError(error)
        }
    }

    func closeDocument() {
        guard confirmClose() else { return }
        document = nil
    }

    /// Asks to save unsaved changes. Returns false if the user cancelled.
    func confirmClose() -> Bool {
        guard let doc = document, doc.isDirty else { return true }
        let a = NSAlert()
        a.messageText = "是否保存对「\(doc.title)」的修改？"
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "不保存")
        a.addButton(withTitle: "取消")
        switch a.runModal() {
        case .alertFirstButtonReturn: return Exporter.save(doc)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func startPresentation(fromBeginning: Bool = false) {
        guard let doc = document, presenter == nil else { return }
        if fromBeginning { doc.go(to: 0) }
        doc.selection = []
        let p = PresentationController(document: doc, tools: tools, recorder: recorder)
        p.onClose = { [weak self] in self?.presenter = nil }
        presenter = p
        p.show()
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        if let doc = app.document {
            EditorView(doc: doc)
                .id(ObjectIdentifier(doc))
        } else {
            HomeView()
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var app: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { UpdateWindow.checkNow() }
        }
        CommandGroup(replacing: .newItem) {
            Button("新建课件") { app.newDocument() }.keyboardShortcut("n")
            Button("打开课件…") { app.openWithPanel() }.keyboardShortcut("o")
            Divider()
            Button("关闭课件") { app.closeDocument() }.keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(app.document == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存") { if let d = app.document { Exporter.save(d) } }.keyboardShortcut("s").disabled(app.document == nil)
            Button("另存为…") { if let d = app.document { Exporter.save(d, forceChoose: true) } }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(app.document == nil)
        }
        CommandGroup(after: .importExport) {
            Button("导出为 .enbx…") { if let d = app.document { Exporter.exportEnbx(d) } }.disabled(app.document == nil)
            Button("导出为 PDF…") { if let d = app.document { Exporter.exportPDF(d) } }.keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(app.document == nil)
            Button("导出为图片…") { if let d = app.document { Exporter.exportImages(d) } }.disabled(app.document == nil)
        }
        // Cut/copy/paste/undo go through the responder chain (BoardCanvasView implements
        // them) so text fields keep their own editing commands.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("创建副本") { app.document?.duplicateSelection() }.keyboardShortcut("d")
            Button("组合") { app.document?.groupSelection() }.keyboardShortcut("g")
            Button("取消组合") { app.document?.ungroupSelection() }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandMenu("授课") {
            Button("从当前页开始授课") { app.startPresentation() }.keyboardShortcut(.return, modifiers: [.command])
                .disabled(app.document == nil)
            Button("从第一页开始授课") { app.startPresentation(fromBeginning: true) }.keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(app.document == nil)
            Divider()
            Button("新建页面") { app.document?.addSlide() }.keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(app.document == nil)
        }
    }
}
