import SwiftUI
import XiwoCore

/// Start page: recent files and recent lecture recordings. New courseware starts blank;
/// its background is picked in the inspector.
struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @State private var recent: [URL] = RecentFiles.urls

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Text("今天讲什么课？")
                        .font(.system(size: 30, weight: .regular, design: .serif))
                        .foregroundStyle(Theme.text)
                        .padding(.top, 8)
                    recentSection
                    RecentRecordingsSection()
                }
                .frame(maxWidth: 920, alignment: .leading)
                .padding(.horizontal, 48).padding(.vertical, 56)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.background)
        }
        .tint(Theme.accent)
        .onAppear { recent = RecentFiles.urls }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "最近打开") {
                if !recent.isEmpty { Button("打开其他课件…") { app.openWithPanel() } }
            }
            if recent.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.tertiaryText)
                    VStack(spacing: 4) {
                        Text("还没有课件").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                        Text("新建一个，或打开 .xwb / .enbx 文件").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    HStack(spacing: 8) {
                        Button { app.newDocument() } label: { Label("新建课件", systemImage: "plus") }
                            .buttonStyle(PrimaryButtonStyle())
                        Button { app.openWithPanel() } label: { Text("打开课件…") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 36)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.prefix(8).enumerated()), id: \.element) { i, url in
                        if i > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 50) }
                        RecentFileRow(url: url, modified: modified(url)) { app.open(url) }
                            .contextMenu {
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("从列表中移除") { RecentFiles.remove(url); recent = RecentFiles.urls }
                            }
                    }
                }
                .padding(4)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                // The app icon itself, so the home page always matches the Dock.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                Text("讲课板").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10)
            .padding(.top, 44) // clear the traffic lights
            .padding(.bottom, 20)
            Button { app.newDocument() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Theme.accent, in: Circle())
                    Text("新建课件").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9).frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            SidebarRow(title: "打开课件…", systemImage: "folder") { app.openWithPanel() }
            SidebarRow(title: "示例课件", systemImage: "sparkles") {
                if app.confirmClose() { app.document = DocumentModel(courseware: SampleCourseware.make()) }
            }
            Spacer()
            HStack {
                Text("版本 \(Updater.shared.currentVersion)")
                Spacer()
                Button("检查更新") { UpdateWindow.checkNow() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.tertiaryText)
            .padding(.horizontal, 10)
        }
        .padding(.horizontal, 10).padding(.bottom, 16)
        .frame(width: 232)
        .background(Theme.sidebar)
    }

    private func modified(_ url: URL) -> String {
        guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return "" }
        return d.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
    }
}

/// Section title with an optional quiet action on the right.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            Spacer()
            trailing()
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 4)
    }
}

private struct RecentFileRow: View {
    let url: URL
    let modified: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: url.pathExtension.lowercased() == "enbx" ? "doc.richtext" : "rectangle.on.rectangle")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(Theme.hover, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 16)
                Text(modified).font(.system(size: 11.5)).foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
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
