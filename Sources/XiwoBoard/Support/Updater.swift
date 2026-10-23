import AppKit
import CryptoKit
import OSLog
import SwiftUI
import XiwoCore

private let log = Logger(subsystem: "io.github.haozhanghz.xiwoboard", category: "updater")

/// Checks the GitHub releases of this project for a newer build and installs it
/// in place: download the arm64 zip, check its SHA-256, unpack, verify the
/// signature and version, swap the app bundle and reopen. A copy that runs from
/// a read-only place cannot be swapped, so its update goes to /Applications.
///
/// Releases are signed with the project's own certificate (docs/SIGNING.md), not
/// a Developer ID, so there is no Sparkle-style signature to check; the published
/// `.sha256` and `codesign --verify` guard against a corrupt or truncated download.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repository = "haozhanghz/xiwo-board"

    struct Asset: Equatable {
        let name: String
        let apiURL: URL
    }

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
        let archive: Asset
        let checksum: Asset?
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case ready(Release)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    @Published var autoCheck = Defaults.bool(Keys.autoCheck, default: true) {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Keys.autoCheck) }
    }
    private var skippedVersion: String {
        get { UserDefaults.standard.string(forKey: Keys.skippedVersion) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.skippedVersion) }
    }
    private var lastCheck: Double {
        get { UserDefaults.standard.double(forKey: Keys.lastCheck) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastCheck) }
    }

    private enum Keys {
        static let autoCheck = "updates.autoCheck"
        static let skippedVersion = "updates.skippedVersion"
        static let lastCheck = "updates.lastCheck"
    }

    private enum Defaults {
        static func bool(_ key: String, default value: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) as? Bool ?? value
        }
    }

    private(set) var stagedApp: URL?
    /// Where `stagedApp` goes; see `installLocation(for:applications:)`.
    private(set) var installTarget: URL?
    private var stagingDirectory: URL?
    /// Where an update goes when this copy cannot be replaced where it is.
    static var applicationsFolder = URL(fileURLWithPath: "/Applications")

    /// True when this copy runs from a read-only place, so the update goes to /Applications.
    var movesToApplications: Bool { Self.isReadOnlyLocation(Bundle.main.bundleURL) }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: Checking

    /// Checks at most once a day when the app starts; stays silent unless there is an update.
    func checkOnLaunch() async {
        guard autoCheck, Date().timeIntervalSince1970 - lastCheck > 20 * 3600 else { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        switch phase {
        case .checking, .downloading, .ready: return
        default: break
        }
        phase = .checking
        do {
            let release = try await fetchLatest()
            lastCheck = Date().timeIntervalSince1970
            guard let latest = AppVersion(release.version), let current = AppVersion(currentVersion), current < latest else {
                phase = userInitiated ? .upToDate : .idle
                return
            }
            if !userInitiated && skippedVersion == release.version {
                phase = .idle
                return
            }
            phase = .available(release)
            if !userInitiated { UpdateWindow.show() }
        } catch {
            log.error("Update check failed: \(String(describing: error), privacy: .public)")
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// Shows `release` as available without asking GitHub (used by `--snapshot`).
    func preview(_ release: Release) { phase = .available(release) }

    func skip(_ release: Release) {
        skippedVersion = release.version
        phase = .idle
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 403, 404: throw UpdateError.noAccess
        default: throw UpdateError.http(status)
        }
        let json = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let zip = json.assets.first(where: { $0.name.hasSuffix("-arm64.zip") }) else { throw UpdateError.noArchive }
        let sum = json.assets.first { $0.name == zip.name + ".sha256" }
        guard sum != nil else { throw UpdateError.noChecksum }
        return Release(version: AppVersion(json.tagName)?.description ?? json.tagName,
                       notes: json.body ?? "",
                       page: json.htmlURL,
                       archive: Asset(name: zip.name, apiURL: zip.url),
                       checksum: sum.map { Asset(name: $0.name, apiURL: $0.url) })
    }

    // MARK: Installing

    func download(_ release: Release) async {
        guard case .available(let available) = phase, available == release else { return }
        phase = .downloading(release)
        do {
            clearStaging()
            let target = try Self.installLocation(for: Bundle.main.bundleURL, applications: Self.applicationsFolder)
            // Staged on the target's volume, so installing is a rename. The running copy's
            // own volume may be read-only, which is what made staging fail before.
            let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: target.deletingLastPathComponent(), create: true)
            stagingDirectory = staging
            let zip = staging.appendingPathComponent(release.archive.name)
            try await fetch(release.archive, to: zip)
            guard let checksum = release.checksum else { throw UpdateError.noChecksum }
            let sumFile = staging.appendingPathComponent(checksum.name)
            try await fetch(checksum, to: sumFile)
            let expected = try String(contentsOf: sumFile, encoding: .utf8).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let actual = try await Task.detached(priority: .utility) { try Self.sha256(of: zip) }.value
            guard expected.lowercased() == actual else { throw UpdateError.checksumMismatch }
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let app = unpacked.appendingPathComponent("XiwoBoard.app")
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info?["CFBundleShortVersionString"] as? String == release.version else { throw UpdateError.badArchive }
            try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            // Downloads made here are not quarantined, but clear it in case the zip carried it.
            try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
            stagedApp = app
            installTarget = target
            phase = .ready(release)
            log.info("Update \(release.version, privacy: .public) staged at \(app.path, privacy: .public)")
        } catch {
            log.error("Update download failed: \(String(describing: error), privacy: .public)")
            clearStaging()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Swaps the app bundle for the staged one and reopens the app.
    func installAndRelaunch() {
        guard case .ready = phase, let staged = stagedApp, let target = installTarget else { return }
        guard AppModel.shared.confirmClose() else { return }
        do {
            try Self.install(staged, at: target)
            clearStaging()
            // Reopen once this process has exited.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                                  target.path]
            try relaunch.run()
        } catch {
            log.error("Update install failed: \(String(describing: error), privacy: .public)")
            phase = .failed(error.localizedDescription)
            return
        }
        AppModel.shared.skipQuitConfirmation = true
        NSApp.terminate(nil)
    }

    /// Where the update for the copy at `current` goes: over that copy, unless it runs
    /// from a read-only place. macOS runs an app opened straight from Downloads out of
    /// a randomized read-only mount (App Translocation), and a disk image is read-only
    /// too; such a copy cannot be replaced, so the update goes to `applications`.
    nonisolated static func installLocation(for current: URL, applications: URL) throws -> URL {
        let fm = FileManager.default
        if !isReadOnlyLocation(current) {
            let folder = current.deletingLastPathComponent()
            guard fm.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable(folder.path) }
            return current
        }
        guard fm.isWritableFile(atPath: applications.path) else { throw UpdateError.translocated }
        return applications.appendingPathComponent("XiwoBoard.app")
    }

    nonisolated static func isReadOnlyLocation(_ url: URL) -> Bool {
        url.path.contains("/AppTranslocation/")
            || (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    /// Puts the staged app at `target`, over the copy already there if any.
    nonisolated static func install(_ staged: URL, at target: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            // New metadata only, so a quarantine flag on the old copy is not carried over.
            _ = try fm.replaceItemAt(target, withItemAt: staged, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: staged, to: target)
        }
    }

    private func fetch(_ asset: Asset, to destination: URL) async throws {
        var request = URLRequest(url: asset.apiURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (file, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    private func clearStaging() {
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
        stagingDirectory = nil
        stagedApp = nil
        installTarget = nil
    }

    /// Stream hashing off the main actor keeps large updates out of UI memory.
    nonisolated private static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    c.resume()
                } else {
                    c.resume(throwing: UpdateError.toolFailed((tool as NSString).lastPathComponent, p.terminationStatus))
                }
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }

    enum UpdateError: LocalizedError {
        case noAccess
        case http(Int)
        case noArchive
        case noChecksum
        case checksumMismatch
        case badArchive
        case toolFailed(String, Int32)
        case translocated
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .noAccess:
                return "暂时无法访问 GitHub 的发布页面，可能是访问次数超限，请稍后再试。"
            case .http(let code): return "下载失败（HTTP \(code)）。"
            case .noArchive: return "最新版本里没有找到 Apple 芯片的安装包。"
            case .noChecksum: return "最新版本缺少校验文件，暂时无法在应用内安装，请前往发布页面查看。"
            case .checksumMismatch: return "下载的文件校验不通过，可能下载不完整，请重试。"
            case .badArchive: return "安装包内容不对（应用标识或版本号不符）。"
            case .toolFailed(let tool, let code): return "\(tool) 执行失败（\(code)）。"
            case .translocated: return "XiwoBoard 正在只读的临时位置运行，也没有权限写入「应用程序」文件夹。请退出后在 Finder 里把它拖进「应用程序」，从那里打开后再更新。"
            case .notWritable(let dir): return "没有权限写入 \(dir)。请把 XiwoBoard 放到你有写入权限的文件夹（如「应用程序」）后再更新。"
            }
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let body: String?
    let htmlURL: URL
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", body, htmlURL = "html_url", assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let url: URL
}

// MARK: - Window

@MainActor
enum UpdateWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: UpdateView().environmentObject(Updater.shared)))
            w.title = "软件更新"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Opens the window and checks right away (检查更新…).
    static func checkNow() {
        show()
        Task { await Updater.shared.check(userInitiated: true) }
    }
}

struct UpdateView: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("XiwoBoard 更新").font(.title3.bold())
                    Text("当前版本 \(updater.currentVersion)").foregroundStyle(.secondary)
                }
            }
            status
            Divider()
            Toggle("启动时自动检查更新", isOn: $updater.autoCheck)
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private var status: some View {
        switch updater.phase {
        case .idle:
            Button("检查更新") { Task { await updater.check(userInitiated: true) } }
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在检查更新…") }
        case .upToDate:
            HStack {
                Label("已是最新版本", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("再次检查") { Task { await updater.check(userInitiated: true) } }
            }
        case .available(let r):
            VStack(alignment: .leading, spacing: 10) {
                Text("发现新版本 \(r.version)").font(.headline)
                ReleaseNotes(text: r.notes)
                if updater.movesToApplications {
                    Text("XiwoBoard 现在在只读的临时位置运行（比如直接在「下载」里打开）。新版本会装进「应用程序」文件夹，以后请从那里打开。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("跳过这个版本") { updater.skip(r) }
                    Link("在网页上查看", destination: r.page)
                    Spacer()
                    Button("下载并安装") { Task { await updater.download(r) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .downloading(let r):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在下载并校验 \(r.version)…") }
        case .ready(let r):
            VStack(alignment: .leading, spacing: 10) {
                Text(updater.movesToApplications
                     ? "\(r.version) 已下载并校验，会装进「应用程序」文件夹。重新打开 XiwoBoard 即可完成更新。"
                     : "\(r.version) 已下载并校验。重新打开 XiwoBoard 即可完成更新。")
                Text("更新后，系统可能会再次请求录屏和麦克风权限。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("立即重新打开") { updater.installAndRelaunch() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") { Task { await updater.check(userInitiated: true) } }
            }
        }
    }
}

/// Release notes are Markdown; headings and list items are laid out line by line.
private struct ReleaseNotes: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(height: 220)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            Text(inline(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))).font(.headline).padding(.top, 6)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(String(trimmed.dropFirst(2))))
            }
            .padding(.leading, CGFloat(line.prefix { $0 == " " }.count) * 4)
        } else if !trimmed.isEmpty {
            Text(inline(trimmed))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
