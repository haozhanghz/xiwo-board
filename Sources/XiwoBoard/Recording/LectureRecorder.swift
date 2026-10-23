import AVFoundation
import AppKit
import CoreMedia
import OSLog
import ScreenCaptureKit
import XiwoCore

private let log = Logger(subsystem: "io.github.haozhanghz.xiwoboard", category: "recorder")

/// Records the lecture (录屏讲课) with ScreenCaptureKit: the presentation screen,
/// the microphone and optionally system audio, written straight to an MP4 by
/// `SCRecordingOutput`.
///
/// Pausing finishes the current part of the video and ends its capture; resuming
/// starts a new capture into the next part. Stopping joins the parts
/// (`RecordingMerger`), so the paused time is not in the video.
///
/// When `coursewareOnly` is on, the presenter's own panels (toolbar, page list,
/// timer…) are left out of the capture, so the video shows only the courseware
/// and the teacher's ink, while the teacher still sees and uses the tools.
///
/// Each step is logged under the `recorder` category, so a failed start can be
/// traced with `log show --predicate 'subsystem == "io.github.haozhanghz.xiwoboard"'`.
@MainActor
final class LectureRecorder: NSObject, ObservableObject {
    enum State: Equatable { case idle, starting, recording, paused, stopping }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastRecording: URL?
    @Published var coursewareOnly = true { didSet { if oldValue != coursewareOnly { refreshFilter() } } }
    @Published var recordMicrophone = true
    @Published var recordSystemAudio = false
    /// Off by default so the pointer stays out of the video. The laser pointer is drawn
    /// on the slide itself, so pointing at things still shows up.
    @Published var recordCursor = false

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var timer: Timer?
    /// When the part being written began; nil while paused.
    private var partStart: Date?
    /// Recorded time in the parts already closed.
    private var recordedBefore: TimeInterval = 0
    private weak var targetWindow: NSWindow?
    private var chromeWindows: () -> [NSWindow] = { [] }
    private let frameSink = FrameSink()
    /// The finished video. The first part is written here; later ones next to it.
    private var outputURL: URL?
    private var partURL: URL?
    private var parts: [URL] = []
    /// The pause or resume in progress; the next one, and stop, wait for it.
    private var step: Task<Error?, Never>?
    private var finishWaiter: CheckedContinuation<Void, Error>?
    private var outputResult: Result<Void, Error>?
    private var finishTimeout: Task<Void, Never>?
    private var stopRequested = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    /// True from the start of a recording until it is saved, paused or not.
    var isRecording: Bool { state == .recording || state == .paused }
    var isPaused: Bool { state == .paused }

    /// Starts recording the screen that shows `window`.
    /// `chrome` returns the tool windows to hide when `coursewareOnly` is on.
    func start(window: NSWindow, title: String, chrome: @escaping () -> [NSWindow]) async {
        guard state == .idle else { return }
        stopRequested = false
        outputURL = nil
        parts = []
        recordedBefore = 0
        state = .starting
        defer {
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        targetWindow = window
        chromeWindows = chrome
        log.info("Start requested (mic: \(self.recordMicrophone), system audio: \(self.recordSystemAudio), cursor: \(self.recordCursor), courseware only: \(self.coursewareOnly))")

        guard Self.ensureScreenAccess(), await ensureMicrophoneAccess(), !stopRequested else {
            state = .idle
            return
        }
        do {
            let (filter, display) = try await makeFilter()
            guard !stopRequested else { state = .idle; return }
            let url = Self.makeOutputURL(title: title)
            try await beginPart(at: url, filter: filter, display: display)
            outputURL = url
            elapsed = 0
            state = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let d = self.partStart else { return }
                    self.elapsed = self.recordedBefore + Date().timeIntervalSince(d)
                }
            }
        } catch {
            log.error("Start failed: \(String(describing: error), privacy: .public)")
            state = .idle
            Self.report(error)
        }
    }

    func stop() async { await stop(reporting: nil) }

    /// Ends the recording and saves it. `cause` is a failure that cut the recording
    /// short; it is shown once everything recorded so far is saved.
    private func stop(reporting cause: Error?) async {
        if state == .starting {
            stopRequested = true
            await withCheckedContinuation { startWaiters.append($0) }
        }
        // A pause or resume in progress, and any queued behind it, finishes first.
        var finished: Task<Error?, Never>?
        while let current = step, current != finished {
            _ = await current.value
            finished = current
        }
        if state == .stopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        guard isRecording else { return }
        state = .stopping
        defer {
            let waiters = stopWaiters
            stopWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        timer?.invalidate(); timer = nil
        var failure = cause
        if let error = await endPart(), failure == nil { failure = error }
        var saved: URL?
        if let url = outputURL, !parts.isEmpty {
            do {
                saved = try await save(parts, as: url)
            } catch {
                log.error("Joining \(self.parts.count) parts failed: \(String(describing: error), privacy: .public)")
                if failure == nil { failure = RecorderError.partsKept(parts.count, error) }
            }
        }
        state = .idle
        if let failure { Self.report(failure) }
        if let saved {
            lastRecording = saved
            log.info("Recording saved")
            if failure == nil { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
        }
    }

    /// Finishes the current part of the video and ends its capture until `resume()`,
    /// so nothing is recorded while paused.
    func pause() async {
        let failure = await serially { [self] in
            guard state == .recording else { return nil }
            if let partStart { recordedBefore += Date().timeIntervalSince(partStart) }
            elapsed = recordedBefore
            state = .paused
            log.info("Pausing after \(Int(self.recordedBefore)) s")
            return await endPart()
        }
        if let failure { await stop(reporting: failure) }
    }

    /// Starts the next part of the video with a new capture.
    func resume() async {
        let failure = await serially { [self] in
            guard state == .paused, let first = outputURL else { return nil }
            do {
                let (filter, display) = try await makeFilter()
                try await beginPart(at: Self.partURL(after: first, number: parts.count + 1), filter: filter, display: display)
            } catch {
                return error
            }
            state = .recording
            return nil
        }
        if let failure { await stop(reporting: failure) }
    }

    /// Runs pauses and resumes one after another, so a quick second click waits for
    /// the first to finish with its capture.
    private func serially(_ body: @escaping @MainActor () async -> Error?) async -> Error? {
        let previous = step
        let task = Task { @MainActor in
            _ = await previous?.value
            return await body()
        }
        step = task
        return await task.value
    }

    /// Starts a capture of the presentation screen that writes one part of the video
    /// to `url`. Each part gets a capture of its own, which writes its first frame
    /// even when nothing on the screen moves.
    private func beginPart(at url: URL, filter: SCContentFilter, display: SCDisplay) async throws {
        let config = SCStreamConfiguration()
        let pixelsPerPoint = Double(filter.pointPixelScale)
        let size = CaptureSize(width: Double(filter.contentRect.width) * pixelsPerPoint,
                               height: Double(filter.contentRect.height) * pixelsPerPoint)
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = recordCursor
        config.queueDepth = 6
        config.capturesAudio = recordSystemAudio
        config.excludesCurrentProcessAudio = false
        let microphone = recordMicrophone ? AVCaptureDevice.default(for: .audio) : nil
        config.captureMicrophone = microphone != nil
        if let microphone { config.microphoneCaptureDeviceID = microphone.uniqueID }
        log.info("Capturing display \(display.displayID) at \(config.width)x\(config.height), microphone: \(microphone?.localizedName ?? "none", privacy: .public)")

        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = .mp4
        rc.videoCodecType = .h264
        let rec = SCRecordingOutput(configuration: rc, delegate: self)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        stream = s
        output = rec
        partURL = url
        outputResult = nil
        do {
            try s.addStreamOutput(frameSink, type: .screen, sampleHandlerQueue: frameSink.queue)
            try s.addRecordingOutput(rec)
            try await s.startCapture()
            if let outputResult {
                try outputResult.get()
                throw RecorderError.finishedBeforeStart
            }
        } catch {
            try? await s.stopCapture()
            stream = nil
            output = nil
            throw error
        }
        partStart = Date()
        log.info("Recording to \(url.path, privacy: .public)")
    }

    /// Finishes the part being written and ends its capture. Returns what went wrong.
    private func endPart() async -> Error? {
        guard let s = stream else { return nil }
        var failure: Error?
        // Removing the recording output finalises the file; wait for that before
        // tearing down the stream.
        if let output {
            do {
                try s.removeRecordingOutput(output)
                try await waitForFinish()
                if let partURL { parts.append(partURL) }
            } catch {
                log.error("Removing recording output failed: \(String(describing: error), privacy: .public)")
                failure = error
            }
        }
        do { try await s.stopCapture() } catch {
            log.error("Stop capture failed: \(String(describing: error), privacy: .public)")
            if failure == nil { failure = error }
        }
        stream = nil
        output = nil
        partStart = nil
        return failure
    }

    /// Leaves a single part where it is; joins several into `url`, replacing the first
    /// part, and deletes the rest. If joining fails the parts stay on disk.
    private func save(_ parts: [URL], as url: URL) async throws -> URL? {
        let parts = parts.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard parts.count > 1 else { return parts.first }
        log.info("Joining \(parts.count) parts")
        let joined = url.deletingPathExtension().appendingPathExtension("joining.mp4")
        do {
            try await RecordingMerger.merge(parts, into: joined)
        } catch {
            try? FileManager.default.removeItem(at: joined)
            throw error
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: joined)
        } else {
            try FileManager.default.moveItem(at: joined, to: url)
        }
        for part in parts where part != url { try? FileManager.default.removeItem(at: part) }
        return url
    }

    private func waitForFinish() async throws {
        if let outputResult { return try outputResult.get() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            finishWaiter = c
            finishTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                self?.completeOutput(.failure(RecorderError.finishTimedOut))
            }
        }
    }

    private func completeOutput(_ result: Result<Void, Error>) {
        guard outputResult == nil else { return }
        outputResult = result
        finishTimeout?.cancel()
        finishTimeout = nil
        finishWaiter?.resume(with: result)
        finishWaiter = nil
    }

    /// Shows a recording state without capturing anything, for `--snapshot`.
    func preview(_ state: State, elapsed: TimeInterval) {
        self.state = state
        self.elapsed = elapsed
    }

    /// Re-applies the filter, e.g. after the tool panels change or `coursewareOnly` flips.
    func refreshFilter() {
        guard let stream, isRecording else { return }
        Task {
            guard let (filter, _) = try? await makeFilter() else { return }
            try? await stream.updateContentFilter(filter)
        }
    }

    private func makeFilter() async throws -> (SCContentFilter, SCDisplay) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let screenID = (targetWindow?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let apps = content.applications.filter { $0.processID == pid }
        var excluded: [SCWindow] = []
        if coursewareOnly {
            let ids = Set(chromeWindows().filter(\.isVisible).map { CGWindowID($0.windowNumber) })
            excluded = content.windows.filter { ids.contains($0.windowID) }
        }
        log.debug("Filter: \(apps.count) app(s), \(excluded.count) tool window(s) excluded")
        // Capture only our own windows so notifications and other apps stay out of the lecture.
        let filter = apps.isEmpty
            ? SCContentFilter(display: display, excludingWindows: excluded)
            : SCContentFilter(display: display, including: apps, exceptingWindows: excluded)
        return (filter, display)
    }

    // MARK: Permissions

    private static let askedForScreenKey = "recorder.askedForScreenAccess"

    /// Screen recording needs the 录屏与系统录音 permission, which only takes effect
    /// after the app is reopened.
    private static func ensureScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let firstTime = !UserDefaults.standard.bool(forKey: askedForScreenKey)
        UserDefaults.standard.set(true, forKey: askedForScreenKey)
        // The first request shows the system prompt; later ones just return false.
        if CGRequestScreenCaptureAccess() { return true }
        log.notice("Screen recording permission missing (first request: \(firstTime))")
        if firstTime { return false }
        let a = NSAlert()
        a.messageText = "需要「录屏与系统录音」权限"
        a.informativeText = "请在「系统设置 › 隐私与安全性 › 录屏与系统录音」中打开 XiwoBoard，然后退出并重新打开 XiwoBoard，再开始录制。"
            + "如果那里的 XiwoBoard 已经打开了（从旧版本更新后会这样），先选中它点「−」删掉，再退出并重新打开 XiwoBoard，开始录制时重新允许。"
        a.addButton(withTitle: "打开系统设置")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { openPrivacySettings("Privacy_ScreenCapture") }
        return false
    }

    /// Returns false to cancel the recording.
    private func ensureMicrophoneAccess() async -> Bool {
        guard recordMicrophone else { return true }
        var status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            status = await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
        }
        log.info("Microphone permission: \(status.rawValue)")
        if status == .authorized { return true }
        let a = NSAlert()
        a.messageText = "无法使用麦克风"
        a.informativeText = "XiwoBoard 没有麦克风权限。可以先不录声音，或者在「系统设置 › 隐私与安全性 › 麦克风」中打开 XiwoBoard。"
        a.addButton(withTitle: "不录声音，继续")
        a.addButton(withTitle: "打开系统设置")
        a.addButton(withTitle: "取消")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            recordMicrophone = false
            return true
        case .alertSecondButtonReturn:
            Self.openPrivacySettings("Privacy_Microphone")
            return false
        default:
            return false
        }
    }

    private static func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// "<name> 片段2.mp4" next to the first part.
    static func partURL(after first: URL, number: Int) -> URL {
        let name = first.deletingPathExtension().lastPathComponent
        return first.deletingLastPathComponent().appendingPathComponent("\(name) 片段\(number).\(first.pathExtension)")
    }

    static func makeOutputURL(title: String) -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = movies.appendingPathComponent("XiwoBoard 录课", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("\(safe) \(f.string(from: Date())).mp4")
    }

    static func report(_ error: Error) {
        let a = NSAlert()
        a.messageText = "录制失败"
        a.informativeText = error.localizedDescription
            + "\n\n如果是首次录制，请在「系统设置 › 隐私与安全性 › 录屏与系统录音」中允许 XiwoBoard，然后重新打开应用。"
        a.runModal()
    }

    enum RecorderError: LocalizedError {
        case noDisplay, finishTimedOut, finishedBeforeStart
        case partsKept(Int, Error)
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "找不到可录制的屏幕"
            case .finishTimedOut: return "录制文件未能及时保存完成，请检查磁盘空间后重试。"
            case .finishedBeforeStart: return "录制意外结束，请重新开始录制。"
            case .partsKept(let n, let error):
                return "暂停前后录下的 \(n) 段视频没能合成一个文件（\(error.localizedDescription)），各段已分别保存在「影片 › XiwoBoard 录课」里。"
            }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

extension LectureRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            log.error("Stream stopped: \(String(describing: error), privacy: .public)")
            guard self.stream === stream else { return }
            self.completeOutput(.failure(error))
            if self.isRecording { await self.stop(reporting: error) }
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        log.info("Recording output started")
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            log.info("Recording output finished")
            guard self.output === recordingOutput else { return }
            self.completeOutput(.success(()))
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            log.error("Recording output failed: \(String(describing: error), privacy: .public)")
            guard self.output === recordingOutput else { return }
            self.completeOutput(.failure(error))
            if self.isRecording { await self.stop(reporting: error) }
        }
    }
}

/// Screen frames go to the recording output; this sink only satisfies the
/// stream's requirement for a screen output.
final class FrameSink: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "xiwo.recorder.frames")
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
