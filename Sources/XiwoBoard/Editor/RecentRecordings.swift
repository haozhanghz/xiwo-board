import AVFoundation
import AppKit
import SwiftUI

/// A lecture recorded with 录屏讲课, as the start page lists it.
struct RecordingFile: Identifiable, Hashable {
    let url: URL
    let modified: Date
    let size: Int64

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    /// The name without the recording time the recorder appends; the card shows the date on its own line.
    var title: String {
        let trimmed = name.replacingOccurrences(of: #"\s*\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}$"#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? name : trimmed
    }

    /// The newest recordings in 「影片 › 录课」, newest first.
    static func recent(limit: Int = 8) -> [RecordingFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: LectureRecorder.recordingsDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        let files = urls.filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return RecordingFile(url: url, modified: v?.contentModificationDate ?? .distantPast, size: Int64(v?.fileSize ?? 0))
        }
        return Array(files.sorted { $0.modified > $1.modified }.prefix(limit))
    }
}

/// 最近录屏: the latest lecture videos, each one a click from playing or sharing.
struct RecentRecordingsSection: View {
    @State private var recordings: [RecordingFile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "最近录屏") {
                Button("打开录课文件夹") { openFolder() }
            }
            if recordings.isEmpty {
                Text("授课时点「录制」录下的视频会出现在这里")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)], alignment: .leading, spacing: 20) {
                    ForEach(recordings) { RecordingCard(file: $0, onChange: reload) }
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private func reload() { recordings = RecordingFile.recent() }

    private func openFolder() {
        let dir = LectureRecorder.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

private struct RecordingCard: View {
    let file: RecordingFile
    let onChange: () -> Void
    @State private var poster: NSImage?
    @State private var duration: TimeInterval?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { NSWorkspace.shared.open(file.url) } label: {
                ZStack(alignment: .bottomTrailing) {
                    Rectangle().fill(Color(white: 0.13))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            if let poster {
                                Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
                            }
                        }
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(.black.opacity(0.45), in: Circle())
                                .opacity(hovering || poster == nil ? 1 : 0)
                        }
                    if let duration {
                        Text(LectureRecorder.format(duration))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .padding(7)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("播放")
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text("\(file.modified.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                ShareLink(item: file.url) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
                .help("分享")
                .accessibilityLabel("分享 \(file.name)")
            }
            .padding(.horizontal, 2)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("播放") { NSWorkspace.shared.open(file.url) }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Button("拷贝") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([file.url as NSURL])
            }
            Divider()
            Button("移到废纸篓") {
                try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                onChange()
            }
        }
        .task(id: file.url) { await loadPoster() }
    }

    private func loadPoster() async {
        let asset = AVURLAsset(url: file.url)
        if let d = try? await asset.load(.duration), d.isNumeric { duration = d.seconds }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let at = CMTime(seconds: min(1, (duration ?? 0) / 2), preferredTimescale: 600)
        if let frame = try? await generator.image(at: at) {
            poster = NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height))
        }
    }
}
