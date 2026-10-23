import CoreGraphics
import Foundation

/// A colour stored as straight (non-premultiplied) RGBA components in 0...1.
public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Parses `#RGB`, `#RRGGBB` and the WPF-style `#AARRGGBB` used by .enbx files.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        switch s.count {
        case 3:
            self.init(Double((v >> 8) & 0xF) / 15, Double((v >> 4) & 0xF) / 15, Double(v & 0xF) / 15)
        case 6:
            self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        case 8:
            self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255,
                      Double(v & 0xFF) / 255, Double((v >> 24) & 0xFF) / 255)
        default:
            return nil
        }
    }

    /// `#AARRGGBB`, the form .enbx expects.
    public var argbHex: String {
        func c(_ x: Double) -> String { String(format: "%02X", Int((max(0, min(1, x)) * 255).rounded())) }
        return "#" + c(a) + c(r) + c(g) + c(b)
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
    public static let clear = RGBA(0, 0, 0, 0)
    public static let red = RGBA(0.92, 0.20, 0.20)
    public static let blue = RGBA(0.13, 0.45, 0.95)
    public static let green = RGBA(0.13, 0.70, 0.35)
    public static let yellow = RGBA(1.0, 0.82, 0.10)
    /// The dark green chalkboard colour that classroom whiteboards default to.
    public static let chalkboard = RGBA(0.13, 0.30, 0.23)

    /// Pen palette shown in the toolbars.
    public static let penPalette: [RGBA] = [
        .black, .white, .red, RGBA(1.0, 0.55, 0.0), .yellow, .green, .blue, RGBA(0.55, 0.25, 0.85),
    ]
}
