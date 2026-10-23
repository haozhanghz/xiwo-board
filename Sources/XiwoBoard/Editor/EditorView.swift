import SwiftUI
import XiwoCore

/// Editing workspace: top toolbar, page thumbnails, canvas, inspector.
struct EditorView: View {
    @ObservedObject var doc: DocumentModel
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var tools: ToolState

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(doc: doc)
            Divider()
            HStack(spacing: 0) {
                SlideSidebar(doc: doc)
                    .frame(width: 180)
                Divider()
                CanvasHost(doc: doc, tools: tools, mode: .edit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView(doc: doc)
                    .frame(width: 270)
            }
            Divider()
            StatusBar(doc: doc)
        }
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

struct StatusBar: View {
    @ObservedObject var doc: DocumentModel

    var body: some View {
        HStack(spacing: 14) {
            Text("第 \(doc.currentIndex + 1) / \(doc.slideCount) 页")
            if !doc.selection.isEmpty { Text("已选择 \(doc.selection.count) 个对象") }
            Spacer()
            Text(doc.isDirty ? "未保存" : (doc.fileURL == nil ? "新课件" : "已保存"))
            Text("\(Int(doc.courseware.slideSize.width))×\(Int(doc.courseware.slideSize.height))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
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
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
                .onMove { doc.moveSlide(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button { doc.addSlide() } label: { Label("新建页面", systemImage: "plus") }
                Spacer()
                Button { doc.deleteSlide(at: doc.currentIndex) } label: { Image(systemName: "trash") }
                    .help("删除当前页")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
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
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
            SlidePreview(slide: slide, courseware: courseware, pixelWidth: 280)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : Color.gray.opacity(0.3),
                                                                  lineWidth: selected ? 2.5 : 1))
        }
    }
}
