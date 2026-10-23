import AppKit

extension Notification.Name {
    /// Posted when a tablet pen's eraser comes into or goes out of range.
    static let tabletEraserChanged = Notification.Name("XiwoBoard.tabletEraserChanged")
}

/// Tracks whether the tablet pointer near the surface is an eraser.
///
/// Tablet drivers such as XPPen's report the pointing device (pen tip, eraser,
/// puck) in proximity events: either a standalone `.tabletProximity` event or a
/// mouse event with the `.tabletProximity` subtype. Those go to the app rather
/// than to a particular view, so one app-wide monitor keeps the state for every
/// canvas. Later pen events carry the same `deviceID`, which ties each press to
/// the device that entered, so a missed "left proximity" cannot leave a plain
/// pen (or the mouse) stuck erasing.
@MainActor
final class TabletInput {
    static let shared = TabletInput()

    /// `deviceID` of the eraser currently in range: the back end of a pen, or a
    /// pen button the driver reports as an eraser.
    private var eraserDevice: Int?
    private var monitor: Any?
    private var resignObserver: Any?

    private init() {}

    /// Starts listening. Safe to call more than once.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.tabletProximity, .mouseMoved]) { event in
            if event.type == .tabletProximity || event.subtype == .tabletProximity {
                MainActor.assumeIsolated { TabletInput.shared.update(event) }
            }
            return event
        }
        // Proximity changes are not delivered while another app is active.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TabletInput.shared.setEraser(nil) }
        }
    }

    /// With an event: whether that press or move comes from the eraser in range.
    /// Without: whether an eraser is in range at all, for cursor and overlay drawing.
    func isEraser(_ event: NSEvent? = nil) -> Bool {
        guard let eraserDevice else { return false }
        guard let event else { return true }
        return event.isFromTablet && event.deviceID == eraserDevice
    }

    private func update(_ event: NSEvent) {
        if event.isEnteringProximity {
            setEraser(event.pointingDeviceType == .eraser ? event.deviceID : nil)
        } else if event.deviceID == eraserDevice || event.pointingDeviceType == .eraser {
            setEraser(nil)
        }
    }

    private func setEraser(_ device: Int?) {
        guard device != eraserDevice else { return }
        eraserDevice = device
        NotificationCenter.default.post(name: .tabletEraserChanged, object: self)
    }
}

extension NSEvent {
    /// The event came from a tablet pen and carries pressure, tilt and `deviceID`.
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
