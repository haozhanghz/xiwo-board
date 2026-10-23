import AVKit
import AppKit
import XiwoCore

/// Plays an audio/video element in place, over the canvas.
@MainActor
enum MediaPlayerOverlay {
    private static var current: (view: NSView, player: AVPlayer, observer: NSObjectProtocol?)?

    static func play(_ element: BoardElement, document: DocumentModel, in canvas: BoardCanvasView) {
        guard case .media(let m) = element.content, let res = document.courseware.resources[m.resource] else { return }
        stop()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xiwo-\(m.resource).\(res.ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try res.data.write(to: url, options: .atomic) }
            catch { Exporter.showError(error); return }
        }
        let player = AVPlayer(url: url)
        let container = NSView(frame: canvas.toView(element.frame).insetBy(dx: 0, dy: m.kind == .audio ? -10 : 0))
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
        canvas.addSubview(container)
        var observer: NSObjectProtocol?
        if m.loop {
            observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak player] _ in
                player?.seek(to: .zero); player?.play()
            }
        }
        player.play()
        current = (container, player, observer)
    }

    static func stop(in canvas: BoardCanvasView? = nil) {
        guard let current, canvas == nil || current.view.superview === canvas else { return }
        if let observer = current.observer { NotificationCenter.default.removeObserver(observer) }
        current.player.pause()
        current.view.removeFromSuperview()
        self.current = nil
    }

    final class CloseTarget: NSObject {
        static let shared = CloseTarget()
        @objc func close() { MainActor.assumeIsolated { MediaPlayerOverlay.stop() } }
    }
}
