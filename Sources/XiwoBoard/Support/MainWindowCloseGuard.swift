import AppKit
import SwiftUI

/// Route the main window's close button through the same save and recording
/// checks as Quit. Cancelling then leaves the editing window on screen.
@MainActor
struct MainWindowCloseGuard: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {}

    static func dismantleNSView(_ nsView: ObserverView, coordinator: Coordinator) { coordinator.detach() }

    final class ObserverView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator?.attach(to: window) }
            else { coordinator?.detach() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        nonisolated(unsafe) private var original: NSWindowDelegate?

        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            detach()
            self.window = window
            original = window.delegate
            window.delegate = self
        }

        func detach() {
            if window?.delegate === self { window?.delegate = original }
            window = nil
            original = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            NSApp.terminate(nil)
            return false
        }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}
