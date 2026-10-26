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
    /// A pill raised off a soft track, lighter than the track in both modes.
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x4A4946)
    /// Behind the page in the editor.
    static let backdrop = Color(nsBackdrop)
    static let nsBackdrop = nsDynamic(light: 0xE9E7DF, dark: 0x1A1918)
    /// Hairlines between panels and around cards.
    static let line = ink.opacity(0.09)
    /// The same line, solid, for straight dividers between panels (drawn as plain fills).
    static let divider = dynamic(light: 0xE4E2DA, dark: 0x3A3936)
    /// Hover and pressed fills for quiet buttons.
    static let hover = ink.opacity(0.06)
    /// Selected rows and active tools.
    static let selected = ink.opacity(0.09)
    /// The track of a switch that is off.
    static let switchOff = ink.opacity(0.16)
    /// Near-black in light mode, near-white in dark: the base of the translucent lines and fills.
    /// Opaque here and faded with opacity(), since a dynamic colour's own alpha is not kept in dark mode.
    private static let ink = dynamic(light: 0x141413, dark: 0xFAF9F5)
    /// Text comes in two colours only, so hierarchy is carried by size and weight.
    static let text = dynamic(light: 0x141413, dark: 0xF5F4EF)
    static let secondaryText = dynamic(light: 0x5F5E58, dark: 0xB8B5AC)
    /// The one accent: primary buttons, selection, focus.
    static let accent = Color(nsAccent)
    static let nsAccent = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0xC4643F) : hex(0xB95A39)
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

/// Motion in three spring tiers, after Fluid Functionalism: the bigger the thing that moves, the
/// slower the spring, and every animation says something (where the pointer is, what is chosen).
/// Exits are plain tweens a tier quicker, so a dismissal reads crisp instead of replaying the entrance.
/// The tiers run about a third quicker than Fluid Functionalism's, so the highlight keeps up with a fast hand.
enum Motion {
    /// Hover highlights, fades, focus: 0.05 s, no bounce.
    static let fast = Animation.spring(duration: 0.05, bounce: 0)
    /// Selection pills, switches, menus: 0.11 s, critically damped, so it lands exactly.
    static let moderate = Animation.spring(duration: 0.11, bounce: 0)
    /// Large surfaces such as panels: 0.18 s with a little bounce.
    static let slow = Animation.spring(duration: 0.18, bounce: 0.12)
    static let fastExit = Animation.easeIn(duration: 0.04)
    /// Colour and weight changes on labels.
    static let tint = Animation.easeOut(duration: 0.05)
    /// Buttons press in at once and spring back almost as quickly.
    static let press = Animation.easeOut(duration: 0.04)
    static let release = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.1)
}

extension View {
    /// The dark warm surface of the floating panels shown while presenting.
    func presenterPanel(cornerRadius: CGFloat = 14) -> some View {
        background(Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x24 / 255).opacity(0.95),
                   in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
    }

    /// Animates a button's press: in fast, out slowly.
    fileprivate func pressMotion(_ pressed: Bool) -> some View {
        animation(pressed ? Motion.press : Motion.release, value: pressed)
    }
}

// MARK: - Fluid hover

/// How a fluid-hover group finds the item nearest the pointer: along a row, down a column, or in a grid.
enum FluidAxis { case x, y, xy }

/// What the items of a fluid-hover group share: where they report their frames, which one is lit,
/// and where they leave their action for clicks that land between items.
struct FluidHoverContext {
    let space: UUID
    let lit: AnyHashable?
    let registry: FluidHoverRegistry
}

/// Item actions and the last pointer position, kept out of view state so moving the pointer
/// within one item does not redraw the group.
final class FluidHoverRegistry {
    var actions: [AnyHashable: () -> Void] = [:]
    var pointer: CGPoint?
}

private struct FluidHoverKey: EnvironmentKey {
    static let defaultValue: FluidHoverContext? = nil
}

private struct FluidHoverPreviewKey: EnvironmentKey {
    static let defaultValue: AnyHashable? = nil
}

extension EnvironmentValues {
    var fluidHover: FluidHoverContext? {
        get { self[FluidHoverKey.self] }
        set { self[FluidHoverKey.self] = newValue }
    }

    /// Lights this item in every group below, as if the pointer were on it (for snapshots).
    var fluidHoverPreview: AnyHashable? {
        get { self[FluidHoverPreviewKey.self] }
        set { self[FluidHoverPreviewKey.self] = newValue }
    }
}

private struct FluidHoverFrames: PreferenceKey {
    static let defaultValue: [AnyHashable: CGRect] = [:]
    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A row, column or grid of buttons sharing one hover highlight. The highlight glides to the item
/// nearest the pointer instead of each button lighting up and going dark on its own, so it never
/// blinks between items, and a click in the gap beside an item goes to the lit one: what is lit is
/// what a click hits. After Fluid Functionalism's "fluid hover".
struct FluidHoverGroup<Content: View>: View {
    var axis: FluidAxis = .x
    var cornerRadius: CGFloat = 8
    /// How far the highlight reaches past each item, e.g. around a card.
    var outset: CGFloat = 0
    /// A click farther than this from the lit item is not passed on to it.
    var gapClickReach: CGFloat = .infinity
    @ViewBuilder var content: () -> Content

    @State private var frames: [AnyHashable: CGRect] = [:]
    @State private var lit: AnyHashable?
    /// Counts pointer entries, so a fresh entry fades in where the pointer is instead of sliding over.
    @State private var session = 0
    @State private var registry = FluidHoverRegistry()
    @State private var space = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fluidHoverPreview) private var preview

    var body: some View {
        let shown = lit ?? preview.flatMap { frames[$0] == nil ? nil : $0 }
        content()
            .environment(\.fluidHover, FluidHoverContext(space: space, lit: shown, registry: registry))
            .onPreferenceChange(FluidHoverFrames.self) { new in
                frames = new
                if let p = registry.pointer { light(nearest(to: p)) }
            }
            .transformPreference(FluidHoverFrames.self) { $0 = [:] }
            .background(alignment: .topLeading) {
                if let shown, let r = frames[shown] {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.hover)
                        .frame(width: r.width + 2 * outset, height: r.height + 2 * outset)
                        .offset(x: r.minX - outset, y: r.minY - outset)
                        // Reduced motion: the highlight jumps to the next item but still fades in and out.
                        .animation(reduceMotion ? nil : Motion.fast, value: r)
                        .id(session)
                        .transition(.asymmetric(insertion: .opacity.animation(Motion.fast),
                                                removal: .opacity.animation(Motion.fastExit)))
                }
            }
            .coordinateSpace(name: space)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    if registry.pointer == nil { session += 1 }
                    registry.pointer = p
                    light(nearest(to: p))
                case .ended:
                    registry.pointer = nil
                    light(nil)
                }
            }
            .onTapGesture { location in
                guard let lit, let r = frames[lit], distance(from: location, to: r) <= gapClickReach else { return }
                registry.actions[lit]?()
            }
    }

    private func light(_ id: AnyHashable?) {
        if id != lit { lit = id }
    }

    /// The item under the pointer, else the one whose centre is nearest, so a pointer in a gap,
    /// in the padding or past the last item still lands on one.
    private func nearest(to p: CGPoint) -> AnyHashable? {
        if let inside = frames.first(where: { $0.value.contains(p) }) { return inside.key }
        return frames.min { a, b in score(p, a.value) < score(p, b.value) }?.key
    }

    private func score(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        switch axis {
        case .x: return abs(p.x - r.midX)
        case .y: return abs(p.y - r.midY)
        case .xy: return hypot(p.x - r.midX, p.y - r.midY)
        }
    }

    private func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }
}

private struct FluidHoverItem: ViewModifier {
    let id: AnyHashable
    let action: (() -> Void)?
    @Environment(\.fluidHover) private var group
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if let group {
            let _ = register(in: group)
            content.background(GeometryReader { g in
                Color.clear.preference(key: FluidHoverFrames.self, value: isEnabled ? [id: g.frame(in: .named(group.space))] : [:])
            })
        } else {
            content
        }
    }

    /// A disabled item never lights up and never takes a click from the gap beside it.
    private func register(in group: FluidHoverContext) -> Bool {
        group.registry.actions[id] = isEnabled ? action : nil
        return true
    }
}

extension View {
    /// Joins the surrounding fluid-hover group as one item; `action` is what a click in the gap beside it does.
    func fluidHoverItem(_ id: AnyHashable, action: (() -> Void)? = nil) -> some View {
        modifier(FluidHoverItem(id: id, action: action))
    }
}

// MARK: - Buttons

/// Borderless button that tints on hover, as in the sidebar and toolbars. Inside a fluid-hover group
/// the group's gliding highlight replaces its own. Pressing pulls the fill in by a point on each side,
/// which reads as a press at any width where a scale would warp a wide button.
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
        @Environment(\.fluidHover) private var group

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .inset(by: configuration.isPressed ? 1 : 0)
                        .fill(fill)
                }
                .opacity(enabled ? 1 : 0.55)
                .onHover { hovering = $0 }
                .animation(Motion.fast, value: hovering)
                .pressMotion(configuration.isPressed)
        }

        private var fill: Color {
            if configuration.isPressed || active { return Theme.selected }
            return hovering && enabled && group == nil ? Theme.hover : .clear
        }
    }
}

/// The filled clay button for the one main action on a screen. Buttons sit on two heights,
/// 36 by default and 28 where space is tight, the same steps as the rows they line up with.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, tint: tint)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: 36)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous).inset(by: configuration.isPressed ? 1 : 0)
                    shape.fill(tint)
                        // Darker under the pointer and darker still while pressed.
                        .overlay(shape.fill(.black.opacity(configuration.isPressed ? 0.14 : hovering && enabled ? 0.08 : 0)))
                }
                .opacity(enabled ? 1 : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
                .animation(Motion.tint, value: hovering)
                .pressMotion(configuration.isPressed)
        }
    }
}

/// An outlined button on the background, for secondary actions. Pressed, the fill and its ring
/// both pull in by a point, so the ring moves inward with the shrinking surface.
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, height: height)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: height < 36 ? 13 : 14))
            .foregroundStyle(Theme.text)
            .opacity(enabled ? 1 : 0.55)
            .padding(.horizontal, height < 36 ? 12 : 16).frame(height: height)
            .background {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous).inset(by: configuration.isPressed ? 1 : 0)
                shape.fill(Theme.surface)
                    .overlay(shape.fill(configuration.isPressed ? Theme.selected : hovering && enabled ? Theme.hover : .clear))
                    .overlay(shape.strokeBorder(Theme.line))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
            .animation(Motion.fast, value: hovering)
            .pressMotion(configuration.isPressed)
    }
}

/// A small text action beside a section title: grey, darkening on a soft fill under the pointer.
/// The icon thickens rather than the label, so the text never changes width.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkButtonBody(configuration: configuration)
    }

    private struct LinkButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(LinkLabelStyle(bold: hovering))
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Theme.text : Theme.secondaryText)
                .padding(.horizontal, 8).frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .inset(by: configuration.isPressed ? 1 : 0)
                        .fill(configuration.isPressed ? Theme.selected : hovering ? Theme.hover : .clear)
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .pointerStyle(.link)
                .animation(Motion.fast, value: hovering)
                .pressMotion(configuration.isPressed)
        }
    }

    private struct LinkLabelStyle: LabelStyle {
        let bold: Bool

        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) {
                configuration.icon.font(.system(size: 12, weight: bold ? .semibold : .regular))
                    .frame(width: 15)
                configuration.title
            }
        }
    }
}

// MARK: - Choices

/// Segmented choice drawn as a soft track with a raised pill that slides to the chosen option.
/// Under the pointer a faint pill rises out of the chosen one and glides to the option it would pick,
/// and the chosen label is the only semibold one, with its width held so nothing shifts.
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @State private var frames: [AnyHashable: CGRect] = [:]
    @State private var hovered: Value?
    @State private var space = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    WeightHeldText(title, bold: selection == value)
                        .font(.system(size: 13))
                        .foregroundStyle(selection == value || hovered == value ? Theme.text : Theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(GeometryReader { g in
                    Color.clear.preference(key: FluidHoverFrames.self, value: [AnyHashable(value): g.frame(in: .named(space))])
                })
                .onHover { inside in
                    if inside { hovered = value } else if hovered == value { hovered = nil }
                }
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .animation(Motion.tint, value: selection)
        .animation(Motion.tint, value: hovered)
        .padding(4)
        .background(alignment: .topLeading) { pills }
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .coordinateSpace(name: space)
        .onPreferenceChange(FluidHoverFrames.self) { frames = $0 }
        .transformPreference(FluidHoverFrames.self) { $0 = [:] }
    }

    @ViewBuilder private var pills: some View {
        let other = hovered.flatMap { $0 == selection ? nil : $0 }
        // The hover pill sits on the chosen one until the pointer picks another option.
        if let r = frames[AnyHashable(other ?? selection)] {
            pill.opacity(other == nil ? 0 : 0.4)
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .animation(reduceMotion ? nil : Motion.fast, value: r)
                .animation(Motion.fast, value: other == nil)
        }
        if let r = frames[AnyHashable(selection)] {
            pill.shadow(color: .black.opacity(0.08), radius: 1.5, y: 0.5)
                // Dims a little while the pointer weighs another option.
                .opacity(other == nil ? 1 : 0.85)
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .animation(reduceMotion ? nil : Motion.moderate, value: r)
                .animation(Motion.fast, value: other == nil)
        }
    }

    /// Concentric with the track: its 10-point corners less the 4-point inset.
    private var pill: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raised)
    }
}

/// A label that turns semibold without changing width: an invisible semibold copy holds the space.
struct WeightHeldText: View {
    let text: String
    let bold: Bool

    init(_ text: String, bold: Bool) {
        self.text = text
        self.bold = bold
    }

    var body: some View {
        ZStack {
            Text(text).fontWeight(.semibold).hidden()
            Text(text).fontWeight(bold ? .semibold : .regular)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A setting as a label and a switch on one row; the whole row flips it. The thumb stretches into a
/// pill under the pointer and squashes as it is pressed, and the label brightens while the setting is on.
struct SettingToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SwitchRowStyle(isOn: configuration.isOn))
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "开" : "关")
    }
}

private struct SwitchRowStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        SwitchRow(configuration: configuration, isOn: isOn)
    }

    private struct SwitchRow: View {
        let configuration: ButtonStyleConfiguration
        let isOn: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let pressed = configuration.isPressed && enabled
            // Past the 16-point thumb: 2 wider under the pointer, 4 wider and 4 shorter pressed.
            let stretch: CGFloat = pressed ? 4 : hovering && enabled ? 2 : 0
            HStack {
                configuration.label
                    .foregroundStyle(isOn ? Theme.text : Theme.secondaryText)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Theme.accent : Theme.switchOff)
                        .overlay(Capsule().fill(.black.opacity(hovering && enabled ? 0.06 : 0)))
                    // Off, the thumb grows rightwards; on, leftwards, so its outer edge stays at the end of the track.
                    Capsule().fill(.white)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                        .frame(width: 16 + stretch, height: pressed ? 12 : 16)
                        .padding(2)
                }
                .frame(width: 34, height: 20)
            }
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(Motion.moderate, value: isOn)
            .animation(Motion.moderate, value: stretch)
            .animation(Motion.tint, value: hovering)
        }
    }
}

/// Icon buttons sharing one soft track, for arrange and align rows; one highlight glides between them.
struct IconGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        FluidHoverGroup(axis: .x, cornerRadius: 6) {
            HStack(spacing: 0) { content() }
        }
        .frame(maxWidth: .infinity)
        .padding(2)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A full-width row in the home sidebar: icon and label. Set inside a fluid-hover group.
struct SidebarRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 18)
                Text(title).font(.system(size: 14)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .fluidHoverItem(title, action: action)
    }
}
