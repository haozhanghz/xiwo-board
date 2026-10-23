import SwiftUI
import XiwoCore

/// Start page: new courseware templates and recent files.
struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @State private var recent: [URL] = RecentFiles.urls

    private let templates: [(String, SlideBackground)] = [
        ("白板", SlideBackground()),
        ("绿板", SlideBackground(color: .chalkboard, patternColor: RGBA(1, 1, 1, 0.3))),
        ("黑板", SlideBackground(color: RGBA(0.12, 0.12, 0.14), patternColor: RGBA(1, 1, 1, 0.3))),
        ("方格", SlideBackground(pattern: .grid)),
        ("四线三格", SlideBackground(pattern: .fourLines, patternColor: RGBA(0.85, 0.3, 0.3))),
        ("田字格", SlideBackground(pattern: .tianzige, patternColor: RGBA(0.2, 0.6, 0.3))),
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("新建课件").font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 18) {
                        ForEach(templates, id: \.0) { name, bg in
                            Button { app.newDocument(background: bg) } label: {
                                VStack(spacing: 8) {
                                    SlidePreview(slide: Slide(background: bg), courseware: Courseware())
                                        .frame(height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                                    Text(name).font(.callout)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Text("最近打开").font(.title2.bold())
                        Spacer()
                        Button("打开课件…") { app.openWithPanel() }
                    }
                    if recent.isEmpty {
                        Text("还没有课件。新建一个，或打开 .xwb / .enbx 文件。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(recent, id: \.self) { url in
                                Button { app.open(url) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: url.pathExtension.lowercased() == "enbx" ? "doc.richtext" : "rectangle.on.rectangle")
                                            .font(.title3).frame(width: 28)
                                            .foregroundStyle(Color.accentColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(url.deletingPathExtension().lastPathComponent).font(.body)
                                            Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        Text(modified(url)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 8).padding(.horizontal, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Button("从列表中移除") { RecentFiles.remove(url); recent = RecentFiles.urls }
                                }
                                Divider()
                            }
                        }
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(32)
            }
        }
        .onAppear { recent = RecentFiles.urls }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [Color(red: 0.13, green: 0.62, blue: 0.42), Color(red: 0.1, green: 0.45, blue: 0.75)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading) {
                    Text("XiwoBoard").font(.headline)
                    Text("课堂白板").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 12)
            Button { app.newDocument() } label: {
                Label("新建课件", systemImage: "plus.rectangle.on.rectangle").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Button { app.openWithPanel() } label: {
                Label("打开课件", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            Button {
                if app.confirmClose() { app.document = DocumentModel(courseware: SampleCourseware.make()) }
            } label: {
                Label("示例课件", systemImage: "sparkles.rectangle.stack").frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            Spacer()
            Text("支持打开 .enbx 课件，\n授课时可原生录制屏幕与麦克风。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("版本 \(Updater.shared.currentVersion)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("检查更新") { UpdateWindow.checkNow() }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(20)
        .frame(width: 220)
        .background(.bar)
    }

    private func modified(_ url: URL) -> String {
        guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return "" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Renders a slide into an image for thumbnails and previews.
struct SlidePreview: View {
    let slide: Slide
    let courseware: Courseware
    var pixelWidth = 320

    var body: some View {
        if let img = SlideRenderer.image(of: slide, courseware: courseware, pixelWidth: pixelWidth) {
            Image(decorative: img, scale: 1).resizable().aspectRatio(courseware.slideSize, contentMode: .fit)
        } else {
            Rectangle().fill(.gray.opacity(0.2))
        }
    }
}
