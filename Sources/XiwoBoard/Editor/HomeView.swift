import SwiftUI
import XiwoCore

/// Start page: recent files. New courseware starts blank; its background is picked in the inspector.
struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @State private var recent: [URL] = RecentFiles.urls

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Text("最近打开").font(.title2.bold())
                        Spacer()
                        Button("打开课件…") { app.openWithPanel() }
                    }
                    if recent.isEmpty {
                        VStack(spacing: 14) {
                            Text("还没有课件。新建一个，或打开 .xwb / .enbx 文件。")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Button { app.newDocument() } label: { Label("新建课件", systemImage: "plus") }
                                    .buttonStyle(.borderedProminent)
                                Button { app.openWithPanel() } label: { Label("打开课件…", systemImage: "folder") }
                            }
                            .controlSize(.large)
                            Text("背景和书写格（绿板、方格、田字格等）在编辑界面点「属性」打开面板来改。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
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
                    Text("讲课板").font(.headline)
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
        if let img = SlidePreviewCache.shared.image(slide: slide, courseware: courseware, pixelWidth: pixelWidth) {
            Image(decorative: img, scale: 1).resizable().aspectRatio(courseware.slideSize, contentMode: .fit)
        } else {
            Rectangle().fill(.gray.opacity(0.2))
        }
    }
}

/// Content-keyed thumbnails survive selection, tool and recording-time updates.
/// Resource keys are content hashes; the full resource blobs stay out of the key.
private final class SlidePreviewCache {
    static let shared = SlidePreviewCache()
    private let images = NSCache<Key, CGImage>()

    private init() {
        images.totalCostLimit = 32 * 1024 * 1024
        images.countLimit = 256
    }

    func image(slide: Slide, courseware: Courseware, pixelWidth: Int) -> CGImage? {
        let key = Key(slide: slide, size: courseware.slideSize, pixelWidth: pixelWidth)
        if let image = images.object(forKey: key) { return image }
        guard let image = SlideRenderer.image(of: slide, courseware: courseware, pixelWidth: pixelWidth) else { return nil }
        images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    private final class Key: NSObject {
        let slide: Slide
        let size: CGSize
        let pixelWidth: Int
        private let cachedHash: Int

        init(slide: Slide, size: CGSize, pixelWidth: Int) {
            var visual = slide
            visual.id = ""
            visual.name = nil
            visual.notes = ""
            visual.transition = .none
            self.slide = visual; self.size = size; self.pixelWidth = pixelWidth
            var hasher = Hasher()
            hasher.combine(visual); hasher.combine(size.width); hasher.combine(size.height); hasher.combine(pixelWidth)
            cachedHash = hasher.finalize()
        }

        override var hash: Int { cachedHash }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return pixelWidth == other.pixelWidth && size == other.size && slide == other.slide
        }
    }
}
