import AppKit

extension Notification.Name {
    /// Posted when a tablet pen enters or leaves proximity, or turns over to its eraser end.
    static let tabletProximityChanged = Notification.Name("XiwoBoard.tabletProximityChanged")
}

/// Tracks which end of a tablet pen is near the surface.
///
/// Tablet drivers such as XPPen's post an `NSEvent.tabletProximity` event when
/// the pen comes into range, naming the pointing device (pen tip, eraser, cursor).
/// Proximity events go to whichever window the pointer is over rather than to a
/// particular view, so a single app-wide monitor keeps the state for every canvas.
@MainActor
final class TabletInput {
    static let shared = TabletInput()

    /// The pen is within range of the tablet.
    private(set) var inProximity = false
    /// The device in range is an eraser: the back end of a pen, or a pen side
    /// button the driver has set to "eraser".
    private(set) var isEraser = false

    private var monitor: Any?

    private init() {}

    /// Starts listening. Safe to call more than once.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.tabletProximity]) { event in
            MainActor.assumeIsolated { TabletInput.shared.update(event) }
            return event
        }
    }

    private func update(_ event: NSEvent) {
        let eraser = event.isEnteringProximity && event.pointingDeviceType == .eraser
        guard event.isEnteringProximity != inProximity || eraser != isEraser else { return }
        inProximity = event.isEnteringProximity
        isEraser = eraser
        NotificationCenter.default.post(name: .tabletProximityChanged, object: self)
    }
}

extension NSEvent {
    /// The event came from a tablet pen and carries pressure and tilt.
    var isFromTablet: Bool {
        switch type {
        case .tabletPoint: return true
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp, .mouseMoved:
            return subtype == .tabletPoint
        default: return false
        }
    }
}
