import AppKit
import SwiftUI

/// The app's palette: warm neutrals with one clay accent, light and dark.
/// Every surface and line in the chrome takes its colour from here.
enum Theme {
    /// Main content background (home page, popovers).
    static let background = dynamic(light: 0xFAF9F5, dark: 0x262624)
    /// Side panels: home sidebar, page list, property panel, status bar.
    static let sidebar = dynamic(light: 0xF3F1EA, dark: 0x1F1E1D)
    /// Raised surfaces on the background: cards, list rows, fields.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x30302E)
    /// Behind the page in the editor.
    static let backdrop = Color(nsBackdrop)
    static let nsBackdrop = nsDynamic(light: 0xE9E7DF, dark: 0x1A1918)
    /// Hairlines between panels and around cards.
    static let line = dynamic(light: 0x141413, dark: 0xFAF9F5, alpha: 0.09)
    /// Hover and pressed fills for quiet buttons.
    static let hover = dynamic(light: 0x141413, dark: 0xFAF9F5, alpha: 0.06)
    /// Selected rows and active tools.
    static let selected = dynamic(light: 0x141413, dark: 0xFAF9F5, alpha: 0.09)
    static let text = dynamic(light: 0x141413, dark: 0xF5F4EF)
    static let secondaryText = dynamic(light: 0x73726C, dark: 0xA6A39A)
    static let tertiaryText = dynamic(light: 0x9C9A92, dark: 0x7A786F)
    /// The one accent: primary buttons, selection, focus.
    static let accent = Color(nsAccent)
    static let nsAccent = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0xE08A6D) : hex(0xC96442)
    }

    static func nsDynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { a in
            (a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light)).withAlphaComponent(alpha)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsDynamic(light: light, dark: dark, alpha: alpha))
    }

    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// The dark warm surface of the floating panels shown while presenting.
    func presenterPanel(cornerRadius: CGFloat = 14) -> some View {
        background(Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x24 / 255).opacity(0.95),
                   in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
    }
}

/// Borderless button that tints on hover, as in the sidebar and toolbars.
struct QuietButtonStyle: ButtonStyle {
    var active = false
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, active: active, cornerRadius: cornerRadius)
    }

    private struct QuietButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        let cornerRadius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fill: Color {
            if configuration.isPressed { return Theme.selected }
            if active { return Theme.selected }
            return hovering && enabled ? Theme.hover : .clear
        }
    }
}

/// The filled clay button for the one main action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 30)
            .background(tint.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// An outlined button on the background, for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).frame(height: 30)
            .background(configuration.isPressed ? Theme.selected : Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A full-width row in the home sidebar: icon and label, tinted on hover.
struct SidebarRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 18)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
    }
}
