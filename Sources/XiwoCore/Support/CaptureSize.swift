import Foundation

/// Even pixel dimensions within the H.264 4K envelope, preserving aspect ratio.
public struct CaptureSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            self.width = 2; self.height = 2
            return
        }
        let scale = min(1, min(3840 / width, 2160 / height))
        self.width = max(2, Int(width * scale) & ~1)
        self.height = max(2, Int(height * scale) & ~1)
    }
}
