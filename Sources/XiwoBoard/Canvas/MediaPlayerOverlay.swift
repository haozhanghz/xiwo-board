import AVKit
import AppKit
import XiwoCore

/// Plays an audio/video element in place, over the canvas.
@MainActor
enum MediaPlayerOverlay {
    private static var current: (view: NSView, player: AVPlayer, observer: NSObjectProtocol?, bar: AudioPlayerBar?)?

    static func play(_ element: BoardElement, document: DocumentModel, in canvas: BoardCanvasView) {
        guard case .media(let m) = element.content, let res = document.courseware.resources[m.resource] else { return }
        stop()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xiwo-\(m.resource).\(res.ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try res.data.write(to: url, options: .atomic) }
            catch { Exporter.showError(error); return }
        }
        let player = AVPlayer(url: url)
        let container: NSView
        var bar: AudioPlayerBar?
        if m.kind == .audio {
            // The system's floating controls drop play/pause when the view is small, and an
            // audio object usually is: use a bar sized for its controls instead.
            let b = AudioPlayerBar(player: player, name: m.name)
            b.place(over: canvas.toView(element.frame), in: canvas.bounds)
            container = b
            bar = b
        } else {
            container = NSView(frame: canvas.toView(element.frame))
            if container.frame.height < 60 { container.frame.size.height = 60 }
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.black.cgColor
            container.layer?.cornerRadius = 8
            let pv = AVPlayerView(frame: container.bounds)
            pv.autoresizingMask = [.width, .height]
            pv.player = player
            pv.controlsStyle = .floating
            container.addSubview(pv)
            let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")!,
                                 target: CloseTarget.shared, action: #selector(CloseTarget.close))
            close.isBordered = false
            close.contentTintColor = .white
            close.frame = NSRect(x: container.bounds.width - 26, y: container.bounds.height - 26, width: 22, height: 22)
            close.autoresizingMask = [.minXMargin, .minYMargin]
            container.addSubview(close)
        }
        canvas.addSubview(container)
        var observer: NSObjectProtocol?
        if m.loop {
            observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak player] _ in
                player?.seek(to: .zero); player?.play()
            }
        }
        player.play()
        current = (container, player, observer, bar)
    }

    static func stop(in canvas: BoardCanvasView? = nil) {
        guard let current, canvas == nil || current.view.superview === canvas else { return }
        if let observer = current.observer { NotificationCenter.default.removeObserver(observer) }
        current.bar?.stopObserving()
        current.player.pause()
        current.view.removeFromSuperview()
        self.current = nil
    }

    final class CloseTarget: NSObject {
        static let shared = CloseTarget()
        @objc func close() { MainActor.assumeIsolated { MediaPlayerOverlay.stop() } }
    }
}

/// A compact player for audio: play/pause, position, times and close, at a size that fits
/// its controls rather than the audio object's, so none of them is squeezed out.
@MainActor
final class AudioPlayerBar: NSView {
    static let size = NSSize(width: 340, height: 44)

    private let player: AVPlayer
    private let playButton = NSButton()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "-:--")
    private let closeButton = NSButton()
    private var timeObserver: Any?

    init(player: AVPlayer, name: String) {
        self.player = player
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
        layer?.cornerRadius = 10
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("音频：\(name)")

        for (button, symbol, action) in [(playButton, "pause.fill", #selector(togglePlay)), (closeButton, "xmark.circle.fill", #selector(closePlayer))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .white
            button.target = self
            button.action = action
        }
        closeButton.setAccessibilityLabel("关闭")
        closeButton.toolTip = "关闭"
        slider.target = self
        slider.action = #selector(seek(_:))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setAccessibilityLabel("播放位置")
        for label in [elapsedLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .white
            label.alignment = .center
        }
        [playButton, elapsedLabel, slider, durationLabel, closeButton].forEach(addSubview)
        layoutControls()
        refresh()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Centres the bar on the audio object's rect, kept inside `bounds`.
    func place(over rect: NSRect, in bounds: NSRect) {
        let width = min(max(rect.width, Self.size.width), max(bounds.width - 16, Self.size.width))
        var frame = NSRect(x: rect.midX - width / 2, y: rect.midY - Self.size.height / 2, width: width, height: Self.size.height)
        frame.origin.x = min(max(frame.minX, bounds.minX + 8), bounds.maxX - 8 - width)
        frame.origin.y = min(max(frame.minY, bounds.minY + 8), bounds.maxY - 8 - frame.height)
        self.frame = frame
        layoutControls()
    }

    func stopObserving() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func layoutControls() {
        let h = bounds.height, button: CGFloat = 30, label: CGFloat = 40
        playButton.frame = NSRect(x: 8, y: (h - button) / 2, width: button, height: button)
        elapsedLabel.frame = NSRect(x: playButton.frame.maxX + 2, y: (h - 16) / 2, width: label, height: 16)
        closeButton.frame = NSRect(x: bounds.width - 8 - button, y: (h - button) / 2, width: button, height: button)
        durationLabel.frame = NSRect(x: closeButton.frame.minX - 2 - label, y: (h - 16) / 2, width: label, height: 16)
        let sliderX = elapsedLabel.frame.maxX + 6
        slider.frame = NSRect(x: sliderX, y: (h - 20) / 2, width: max(40, durationLabel.frame.minX - 6 - sliderX), height: 20)
    }

    private var duration: Double? {
        guard let d = player.currentItem?.duration, d.isNumeric, d.seconds > 0 else { return nil }
        return d.seconds
    }

    @objc private func togglePlay() {
        if player.timeControlStatus == .paused {
            // Played to the end: start again from the top.
            if let duration, player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
        refresh()
    }

    @objc private func seek(_ sender: NSSlider) {
        guard let duration else { return }
        player.seek(to: CMTime(seconds: sender.doubleValue * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsedLabel.stringValue = Self.format(sender.doubleValue * duration)
    }

    @objc private func closePlayer() { MediaPlayerOverlay.stop() }

    private func refresh() {
        let playing = player.timeControlStatus != .paused
        let title = playing ? "暂停" : "播放"
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        playButton.setAccessibilityLabel(title)
        playButton.toolTip = title
        let now = player.currentTime().seconds
        elapsedLabel.stringValue = Self.format(now)
        if let duration {
            durationLabel.stringValue = Self.format(duration)
            // Leave the knob alone while it may be being dragged.
            if NSEvent.pressedMouseButtons & 1 == 0 { slider.doubleValue = min(1, max(0, now / duration)) }
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
