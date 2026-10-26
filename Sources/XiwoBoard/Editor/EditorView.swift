import SwiftUI
import XiwoCore

/// Editing workspace: top toolbar, page thumbnails, canvas, inspector.
struct EditorView: View {
    @ObservedObject var doc: DocumentModel
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var tools: ToolState
    /// The inspector starts collapsed: most lessons are written on the board, not styled here.
    @AppStorage("InspectorShown") private var inspectorShown = false

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(doc: doc)
            Hairline()
            HStack(spacing: 0) {
                SlideSidebar(doc: doc)
                    .frame(width: 184)
                Hairline(vertical: true)
                CanvasHost(doc: doc, tools: tools, mode: .edit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if inspectorShown {
                    Hairline(vertical: true)
                    InspectorView(doc: doc)
                        .frame(width: 280)
                }
            }
            Hairline()
            StatusBar(doc: doc)
        }
        .tint(Theme.accent)
        .onAppear { tools.tool = .select }
    }
}

/// Hosts the AppKit canvas in SwiftUI.
struct CanvasHost: NSViewRepresentable {
    let doc: DocumentModel
    let tools: ToolState
    let mode: BoardCanvasView.Mode

    func makeNSView(context: Context) -> BoardCanvasView {
        let v = BoardCanvasView(document: doc, tools: tools, mode: mode)
        v.onPlayMedia = { [weak v] e in
            guard let v else { return }
            MediaPlayerOverlay.play(e, document: doc, in: v)
        }
        return v
    }

    func updateNSView(_ nsView: BoardCanvasView, context: Context) { nsView.needsDisplay = true }

    static func dismantleNSView(_ nsView: BoardCanvasView, coordinator: ()) {
        nsView.endEditing()
        MediaPlayerOverlay.stop(in: nsView)
    }
}

/// A one-point line in the theme's line colour, between panels.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle().fill(Theme.divider)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

struct StatusBar: View {
    @ObservedObject var doc: DocumentModel

    var body: some View {
        HStack(spacing: 16) {
            Text("第 \(doc.currentIndex + 1) / \(doc.slideCount) 页")
            if !doc.selection.isEmpty { Text("已选择 \(doc.selection.count) 个对象") }
            Spacer()
            HStack(spacing: 5) {
                if doc.isDirty { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                Text(doc.isDirty ? "有未保存的修改" : (doc.fileURL == nil ? "尚未保存" : "已保存"))
            }
            Text("\(Int(doc.courseware.slideSize.width)) × \(Int(doc.courseware.slideSize.height))")
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Theme.background)
    }
}

// MARK: - Page thumbnails

struct SlideSidebar: View {
    @ObservedObject var doc: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(doc.courseware.slides.enumerated()), id: \.element.id) { index, slide in
                    SlideThumbnailRow(index: index, slide: slide, courseware: doc.courseware, selected: index == doc.currentIndex)
                        .equatable()
                        .contentShape(Rectangle())
                        .onTapGesture { doc.go(to: index) }
                        .contextMenu {
                            Button("新建页面") { doc.addSlide(after: index) }
                            Button("复制页面") { doc.duplicateSlide(at: index) }
                            Button("上移") { doc.moveSlide(from: [index], to: max(0, index - 1)) }.disabled(index == 0)
                            Button("下移") { doc.moveSlide(from: [index], to: index + 2) }.disabled(index == doc.slideCount - 1)
                            Divider()
                            Button("删除页面", role: .destructive) { doc.deleteSlide(at: index) }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 12))
                }
                .onMove { doc.moveSlide(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.top, 6)
            HStack(spacing: 2) {
                Button { doc.addSlide() } label: {
                    Label("新建页面", systemImage: "plus")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 8).frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                Button { doc.deleteSlide(at: doc.currentIndex) } label: {
                    Image(systemName: "trash").font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .help("删除当前页")
                .accessibilityLabel("删除当前页")
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .background(Theme.sidebar)
    }
}

struct SlideThumbnailRow: View, Equatable {
    let index: Int
    let slide: Slide
    let courseware: Courseware
    let selected: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.index == b.index && a.slide == b.slide && a.selected == b.selected && a.courseware.slideSize == b.courseware.slideSize
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(selected ? Theme.text : Theme.secondaryText)
                .frame(width: 16, alignment: .trailing)
                .padding(.top, 2)
            SlidePreview(slide: slide, courseware: courseware, pixelWidth: 280)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.line))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
        }
    }
}
