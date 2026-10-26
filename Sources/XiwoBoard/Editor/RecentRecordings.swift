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

    /// The newest recordings in 「影片 › XiwoBoard 录课」, newest first.
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近录屏").font(.title2.bold())
                Spacer()
                Button("打开录课文件夹") { openFolder() }
            }
            if recordings.isEmpty {
                Text("授课时点「录制」录下的视频会出现在这里，可以直接播放或分享。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18)], alignment: .leading, spacing: 18) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { NSWorkspace.shared.open(file.url) } label: {
                ZStack(alignment: .bottomTrailing) {
                    Rectangle().fill(Color.black.opacity(0.85))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            if let poster {
                                Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
                            }
                        }
                        .overlay {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(radius: 4)
                        }
                    if let duration {
                        Text(LectureRecorder.format(duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("播放")
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.callout).lineLimit(2)
                    Text("\(file.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ShareLink(item: file.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("分享")
                .accessibilityLabel("分享 \(file.name)")
            }
        }
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
