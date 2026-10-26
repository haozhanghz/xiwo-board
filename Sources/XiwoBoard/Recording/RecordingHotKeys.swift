import AppKit
import Carbon.HIToolbox

/// ⌥⌘R, ⌥⌘P and ⌥⌘S start, pause and end a lecture recording from any app,
/// while a lecture is on screen. System-wide keys need no extra permission,
/// but they take these keys from other apps, so they are only held while presenting.
@MainActor
final class RecordingHotKeys {
    enum Action: UInt32 { case record = 1, pause, stop }

    /// The key for each action, always with ⌥⌘; the 授课 menu shows the same keys.
    private static let keys: [(Action, Int)] = [(.record, kVK_ANSI_R), (.pause, kVK_ANSI_P), (.stop, kVK_ANSI_S)]

    private static var handlers: [Action: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private static var eventHandler: EventHandlerRef?

    init(_ handlers: [Action: () -> Void]) {
        Self.handlers = handlers
        Self.installEventHandler()
        let signature: OSType = 0x4C4B_4F4B // 'LKOK'
        for (action, key) in Self.keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: action.rawValue)
            if RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
            }
        }
    }

    func invalidate() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        Self.handlers = [:]
    }

    private static func installEventHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let action = Action(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { RecordingHotKeys.handlers[action]?() } }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
