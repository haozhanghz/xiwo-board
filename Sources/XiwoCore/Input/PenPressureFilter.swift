import Foundation

/// Cleans up the pressure stream a graphics tablet reports during one stroke.
///
/// Tablet drivers (XPPen among them) report the raw sensor value with every
/// sample. Two things in that stream show up as ugly ink:
/// - the last sample or two before the pen leaves the surface, and the odd
///   dropout mid-stroke, read close to zero, which pinches the line into a
///   thin tail;
/// - neighbouring samples jitter by a few percent, which makes brush edges
///   ripple once every sample is used instead of a coalesced subset.
///
/// The filter holds the previous value through near-zero readings and applies
/// a light exponential moving average to the rest.
public struct PenPressureFilter: Sendable {
    /// Readings below this are treated as "pen lifting", not as real pressure.
    public var liftThreshold: Double
    /// Weight of each new reading, 0...1. 1 turns smoothing off.
    public var responsiveness: Double
    /// Lowest pressure handed out, so a stroke never vanishes.
    public var floor: Double

    private var last: Double?

    public init(liftThreshold: Double = 0.02, responsiveness: Double = 0.6, floor: Double = 0.05) {
        self.liftThreshold = liftThreshold
        self.responsiveness = responsiveness
        self.floor = floor
    }

    /// Starts a new stroke.
    public mutating func reset() { last = nil }

    /// Feeds one raw reading (0...1) and returns the pressure to draw with.
    public mutating func next(_ raw: Double) -> Double {
        let r = raw.isFinite ? min(1, max(0, raw)) : 0
        guard let l = last else {
            // First contact: nothing to hold yet, so take the reading as is.
            let v = max(floor, r)
            if r >= liftThreshold { last = v }
            return v
        }
        if r < liftThreshold { return l }
        let v = max(floor, l + (r - l) * responsiveness)
        last = v
        return v
    }
}
