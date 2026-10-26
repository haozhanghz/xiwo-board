import AppKit
import SwiftUI

/// Gives the main window a 52-point title bar with no title, so the window buttons sit
/// centred in the editor toolbar's row instead of in a strip of their own above it.
struct MainWindowChrome: NSViewRepresentable {
    /// The top band the window buttons sit in; the editor toolbar is this tall.
    static let barHeight: CGFloat = 52

    func makeNSView(context: Context) -> NSView { WindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.toolbar == nil else { return }
            // An empty toolbar in the unified style is what makes the title bar 52 points tall.
            let toolbar = NSToolbar(identifier: "main")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
    }
}

extension View {
    /// The main window's frame: content runs up under the title bar, which the toolbar row fills.
    func mainWindowChrome() -> some View {
        ignoresSafeArea(.container, edges: .top)
            .background(MainWindowChrome())
    }
}

/// True while the window is full screen, when the window buttons are hidden and their room is not needed.
struct FullScreenReader: ViewModifier {
    @Binding var isFullScreen: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in isFullScreen = true }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in isFullScreen = false }
    }
}
