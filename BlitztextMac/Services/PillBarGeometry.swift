import CoreGraphics

/// Bar metrics of the pill. At level 0 a bar is a round dot (height == width).
enum PillBarGeometry {
    static let barWidth: CGFloat = 2.5
    static let barSpacing: CGFloat = 3.5
    static let maxHeight: CGFloat = 16

    static func height(forLevel level: Float) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        return barWidth + (maxHeight - barWidth) * clamped
    }
}
