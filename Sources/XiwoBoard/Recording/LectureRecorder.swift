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
/// When `coursewareOnly` is on, the presenter's own panels (toolbar, page list,
/// timer…) are left out of the capture, so the video shows only the courseware
/// and the teacher's ink, while the teacher still sees and uses the tools.
///
/// Each step is logged under the `recorder` category, so a failed start can be
/// traced with `log show --predicate 'subsystem == "io.github.haozhanghz.xiwoboard"'`.
@MainActor
final class LectureRecorder: NSObject, ObservableObject {
    enum State: Equatable { case idle, starting, recording, stopping }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastRecording: URL?
    @Published var coursewareOnly = true { didSet { if oldValue != coursewareOnly { refreshFilter() } } }
    @Published var recordMicrophone = true
    @Published var recordSystemAudio = false

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var timer: Timer?
    private var startDate: Date?
    private weak var targetWindow: NSWindow?
    private var chromeWindows: () -> [NSWindow] = { [] }
    private let frameSink = FrameSink()
    private var outputURL: URL?
    private var finishWaiter: CheckedContinuation<Void, Error>?
    private var outputResult: Result<Void, Error>?
    private var finishTimeout: Task<Void, Never>?
    private var stopRequested = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    var isRecording: Bool { state == .recording }

    /// Starts recording the screen that shows `window`.
    /// `chrome` returns the tool windows to hide when `coursewareOnly` is on.
    func start(window: NSWindow, title: String, chrome: @escaping () -> [NSWindow]) async {
        guard state == .idle else { return }
        stopRequested = false
        outputResult = nil
        outputURL = nil
        state = .starting
        defer {
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        targetWindow = window
        chromeWindows = chrome
        log.info("Start requested (mic: \(self.recordMicrophone), system audio: \(self.recordSystemAudio), courseware only: \(self.coursewareOnly))")

        guard Self.ensureScreenAccess(), await ensureMicrophoneAccess(), !stopRequested else {
            state = .idle
            return
        }
        do {
            let (filter, display) = try await makeFilter()
            guard !stopRequested else { state = .idle; return }
            let config = SCStreamConfiguration()
            let pixelsPerPoint = Double(filter.pointPixelScale)
            let size = CaptureSize(width: Double(filter.contentRect.width) * pixelsPerPoint,
                                   height: Double(filter.contentRect.height) * pixelsPerPoint)
            config.width = size.width
            config.height = size.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            config.queueDepth = 6
            config.capturesAudio = recordSystemAudio
            config.excludesCurrentProcessAudio = false
            let microphone = recordMicrophone ? AVCaptureDevice.default(for: .audio) : nil
            config.captureMicrophone = microphone != nil
            if let microphone { config.microphoneCaptureDeviceID = microphone.uniqueID }
            log.info("Capturing display \(display.displayID) at \(config.width)x\(config.height), microphone: \(microphone?.localizedName ?? "none", privacy: .public)")

            let url = Self.makeOutputURL(title: title)
            let rc = SCRecordingOutputConfiguration()
            rc.outputURL = url
            rc.outputFileType = .mp4
            rc.videoCodecType = .h264
            let rec = SCRecordingOutput(configuration: rc, delegate: self)

            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(frameSink, type: .screen, sampleHandlerQueue: frameSink.queue)
            try s.addRecordingOutput(rec)
            stream = s
            output = rec
            outputURL = url
            try await s.startCapture()
            if let outputResult {
                try outputResult.get()
                throw RecorderError.finishedBeforeStart
            }
            startDate = Date()
            elapsed = 0
            state = .recording
            log.info("Recording to \(url.path, privacy: .public)")
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let d = self.startDate else { return }
                    self.elapsed = Date().timeIntervalSince(d)
                }
            }
        } catch {
            log.error("Start failed: \(String(describing: error), privacy: .public)")
            if let stream { try? await stream.stopCapture() }
            stream = nil
            output = nil
            state = .idle
            Self.report(error)
        }
    }

    func stop() async {
        if state == .starting {
            stopRequested = true
            await withCheckedContinuation { startWaiters.append($0) }
        }
        if state == .stopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        guard state == .recording, let s = stream else { return }
        state = .stopping
        defer {
            let waiters = stopWaiters
            stopWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        timer?.invalidate(); timer = nil
        var failure: Error?
        // Removing the recording output finalises the file; wait for that before
        // tearing down the stream.
        if let output {
            do {
                try s.removeRecordingOutput(output)
                try await waitForFinish()
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
        state = .idle
        if let failure {
            Self.report(failure)
        } else if let url = outputURL, FileManager.default.fileExists(atPath: url.path) {
            lastRecording = url
            log.info("Recording saved")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
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

    /// Re-applies the filter, e.g. after the tool panels change or `coursewareOnly` flips.
    func refreshFilter() {
        guard let stream, state == .recording else { return }
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
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "找不到可录制的屏幕"
            case .finishTimedOut: return "录制文件未能及时保存完成，请检查磁盘空间后重试。"
            case .finishedBeforeStart: return "录制意外结束，请重新开始录制。"
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
            if self.state == .recording { await self.stop() }
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
            if self.state == .recording { await self.stop() }
        }
    }
}

/// Screen frames go to the recording output; this sink only satisfies the
/// stream's requirement for a screen output.
final class FrameSink: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "xiwo.recorder.frames")
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
