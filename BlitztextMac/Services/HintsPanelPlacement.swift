import CoreGraphics

/// Geometry of the dictation pill and of the Mail review hints panel next to it.
/// All rects are in AppKit screen coordinates (origin bottom-left, y up).
enum PillGeometry {
    /// Screen rect of the capsule inside the (larger, transparent) pill window.
    static func capsuleRect(inWindowFrame frame: CGRect) -> CGRect {
        CGRect(
            x: frame.midX - PillLayout.pillWidth / 2,
            y: frame.minY + PillLayout.pillBottomInset,
            width: PillLayout.pillWidth,
            height: PillLayout.pillHeight
        )
    }
}

enum HintsPanelPlacement {
    /// Space between the capsule and the hints card.
    static let gap: CGFloat = 8

    /// Rect for the hints card (without shadow margin): horizontally centred on
    /// the capsule, `gap` above it; below it when there is no room above; always
    /// clamped into `visible`.
    static func contentRect(contentSize: CGSize, capsule: CGRect, visible: CGRect) -> CGRect {
        var y = capsule.maxY + gap
        if y + contentSize.height > visible.maxY {
            y = capsule.minY - gap - contentSize.height
        }
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - contentSize.height))

        var x = capsule.midX - contentSize.width / 2
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - contentSize.width))

        return CGRect(origin: CGPoint(x: x, y: y), size: contentSize)
    }
}
